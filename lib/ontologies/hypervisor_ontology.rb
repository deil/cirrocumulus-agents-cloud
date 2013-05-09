require_relative '../config/xen_config'
require_relative 'hypervisor/hypervisor'
require_relative 'hypervisor/hypervisor_db'
require_relative 'hypervisor/mac'
require_relative 'hypervisor/mdraid'
require_relative 'hypervisor/dom_u'
require_relative 'hypervisor/params'
require_relative 'hypervisor/start_guest_saga'

class Storage < KnowledgeClass
  klass 'storage'
  id :number
  property :state
end

class HypervisorOntology < Ontology
  ontology 'hypervisor'

  # (inform (receiver (agent_identifier name "c001v3-hypervisor")) (content (storage 2 state offline)))
  rule 'storage_went_offline', [ Storage.new(:state => :offline) ] do |ontology, params|
    puts "storage number #{params[:NUMBER]} went offline"
    Mdraid.fail_exports(params[:NUMBER].to_i)
  end

  # (inform (receiver (agent_identifier name "c001v3-hypervisor")) (content (storage 2 state online)))
  rule 'storage_goes_online', [ Storage.new(:state => :online) ] do |ontology, params|
    puts "storage number #{params[:NUMBER]} goes online"
    Mdraid.readd_exports(params[:NUMBER].to_i)
  end

  def restore_state
    @logger = Log4r::Logger['ontology::hypervisor']

    add_knowledge_class Storage

    Hypervisor.connect
    Hypervisor.set_cpu(0, 10000, 0)

    discover_new_disks
    collect_initial_guest_stats

    @tick_counter = 0
  end

  def tick
    super.tick

    @tick_counter += 1
    return if @tick_counter < 60

    update_guest_stats

    @tick_counter = 0
  end

  def handle_query(sender, expression, options = {})
    if expression == [:free_memory]
      inform(sender, [[:free_memory], Hypervisor.free_memory], reply(options))
    elsif expression == [:used_memory]
      inform(sender, [[:used_memory], Hypervisor.total_memory - Hypervisor.free_memory], reply(options))
    elsif expression == [:guests_count]
      inform(sender, [[:guests_count], Hypervisor.running_guests.size], reply(options))
    elsif expression == [:guests]
      inform(sender, [[:guests], Hypervisor.running_guests], reply(options))
    else
      super(sender, expression, options)
    end
  end

  def handle_query_if(sender, proposition, options = {})
    if proposition.first == :running
      object = proposition[1]
      if object.first == :guest
        guest = object[1]
        guest_id = object[1].chomp

        inform(sender, Hypervisor.is_guest_running?(guest_id) ? [proposition] : [:not, proposition], reply(options))
      end
    end
  end

  def handle_inform(sender, proposition, options = {})
    super(sender, proposition, options)
  end

  def handle_request(sender, contents, options = {})
    action = contents[0][0]
    if action == :reboot
      object = contents[0][1]
      if object.first == :guest
        guest = object[1]
        guest_id = guest[1].chomp

        Log4r::Logger['ontology::hypervisor'].info "Request: reboot #{guest_id}"

        if reboot_guest(guest_id)
          agree(sender, contents, reply(options))
        else
          refuse(sender, [contents, :guest_not_running], reply(options))
        end
      end
    elsif action == :start
      object = contents[0][1]
      if object.first == :guest
        start_guest(object, sender, contents, options)
      end
    end
  end

  protected

  attr_reader :logger

  def discover_new_disks()
    debug 'Discovering running MD devices'

    Mdraid.list_disks().each do |discovered|
      disk = VirtualDisk.find_by_disk_number(discovered)
      next if disk

      logger.info "autodiscovered virtual disk %d" % [discovered]
      disk = VirtualDisk.new(discovered)
      disk.save('discovered')
    end
  end

  def collect_initial_guest_stats
    running_guests = Hypervisor.running_guests
    running_guests.each do |guest_id|
      guest = Hypervisor.find(guest_id)
      assert [:guest, guest_id, :cpu_time, guest.cpu_time]

      guest.interfaces.each_with_index do |vif, idx|
        assert [:guest, guest_id, :vif, idx, :rx, vif[:rx], :tx, vif[:tx]]
      end

      guest.block.each_key do |dev|
        assert [:guest, guest_id, :block_device, dev, :reads, guest.block[dev][:rd_req], :rd_bytes, guest.block[dev][:rd_bytes], :writes, guest.block[dev][:wr_req], :wr_bytes, guest.block[dev][:wr_bytes]]
      end
    end
  end

  def update_guest_stats
    running_guests = Hypervisor.running_guests
    running_guests.each do |guest_id|
      guest = Hypervisor.find(guest_id)
      replace [:guest, guest_id, :cpu_time, :CPU_TIME], guest.cpu_time

      guest.interfaces.each_with_index do |vif, idx|
        replace [:guest, guest_id, :vif, idx, :rx, :RX, :tx, :TX], {
            :RX => vif[:rx],
            :TX => vif[:tx]
        }
      end

      guest.block.each_key do |dev|
        replace [:guest, guest_id, :block_device, dev, :reads, :RD_REQ, :rd_bytes, :RD_BYTES, :writes, :WR_REQ, :wr_bytes, :WR_BYTES], {
            :RD_REQ => guest.block[dev][:rd_req],
            :RD_BYTES => guest.block[dev][:rd_bytes],
            :WR_REQ => guest.block[dev][:wr_req],
            :WR_BYTES => guest.block[dev][:wr_bytes]
        }
      end
    end
  end

  def reboot_guest(guest_id)
    if Hypervisor.is_guest_running?(guest_id)
      Hypervisor.reset(guest_id)
      return true
    end

    false
  end

  def start_guest(object, sender, contents, options)
    guest_cfg = ParamsParser::guest_config(object)
    guest_id = guest_cfg[:id]

    Log4r::Logger['ontology::hypervisor'].info "Starting guest #{guest_id}"
    Log4r::Logger['ontology::hypervisor'].debug "Guest config: #{guest_cfg.inspect}"

    create_saga(StartGuestSaga).start(guest_cfg, Log4r::Logger['ontology::hypervisor'], sender, contents, reply(options))
  end

end

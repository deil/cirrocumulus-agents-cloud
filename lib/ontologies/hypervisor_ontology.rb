require_relative '../config/xen_config'
require_relative 'hypervisor/hypervisor'
require_relative 'hypervisor/hypervisor_db'
require_relative 'hypervisor/mac'
require_relative 'hypervisor/mdraid'

class HypervisorOntology < Ontology
  ontology 'hypervisor'

  rule 'init', [[:just_started]] do |ontology, params|
    Hypervisor.connect
    Hypervisor.set_cpu(0, 10000, 0)

    ontology.collect_initial_guest_stats

    ontology.retract [:just_started]
  end

  def restore_state
    assert [:just_started]

    discover_new_disks
  end

  def handle_query(sender, expression, options = {})
    if expression == [:free_memory]
      inform(sender, [[:free_memory], Hypervisor.free_memory], reply(options))
    elsif expression == [:used_memory]
      inform(sender, [[:used_memory], Hypervisor.total_memory - Hypervisor.free_memory], reply(options))
    elsif expression == [:guests_count]
      inform(sender, [[:guests_count], Hypervisor.running_guests.size], reply(options))
    else
      super(sender, expression, options)
    end
  end

  def handle_query_if(sender, proposition, options = {})

  end

  def handle_request(sender, contents, options = {})

  end

  def collect_initial_guest_stats
    running_guests = Hypervisor.running_guests
    running_guests.each do |guest_id|
      guest = Hypervisor.find(guest_id)
      debug "#{guest_id}"
      debug "-> CPU = %.02f" % guest.cpu_time
      assert [:guest, guest_id, :cpu_time, guest.cpu_time]

      guest.interfaces.each_with_index do |vif, idx|
        debug "-> vif#{idx} rx=%.02f tx=%.02f" % [vif[:rx]/(1024*1024*1024), vif[:tx]/(1024*1024*1024)]
        assert [:guest, guest_id, :vif, idx, :rx, vif[:rx], :tx, vif[:tx]]
      end

      guest.block.each_key do |dev|
        debug "-> #{dev} reads=%d bytes=%.02f writes=%d bytes %.02f" % [guest.block[dev][:rd_req], guest.block[dev][:rd_bytes]/(1024*1024*1024), guest.block[dev][:wr_req], guest.block[dev][:wr_bytes]/(1024*1024*1024)]
      end
    end
  end

  protected

  def discover_new_disks()
    debug "Discovering running MD devices"

    Mdraid.list_disks().each do |discovered|
      disk = VirtualDisk.find_by_disk_number(discovered)
      next if disk

      logger.info "autodiscovered virtual disk %d" % [discovered]
      disk = VirtualDisk.new(discovered)
      disk.save('discovered')
    end
  end

end

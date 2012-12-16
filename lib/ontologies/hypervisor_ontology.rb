require_relative '../config/xen_config'
require_relative 'hypervisor/hypervisor'
require_relative 'hypervisor/hypervisor_db'
require_relative 'hypervisor/mac'
require_relative 'hypervisor/mdraid'

class HypervisorOntology < Ontology
  ontology 'hypervisor'

  def restore_state
    Hypervisor.connect
    Hypervisor.set_cpu(0, 10000, 0)

    discover_new_disks
    collect_initial_guest_stats
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
    p proposition
    if proposition.first == :running

    end
  end

  def handle_request(sender, contents, options = {})

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

end

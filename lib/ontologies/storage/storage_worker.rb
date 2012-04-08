require "#{AGENT_ROOT}/standalone/linux/#{STORAGE_CONFIG[:backend]}/storage_node.rb"

# Worker class for Storage ontology. Performs low-level operations
class StorageWorker
  # Creates new virtual disk, brings it export up and adds this information to local database
  #
  # * *Args* :
  #   - +disk_number+ -> number of new virtual disk, should be unique
  #   - +disk_slot+   -> slot for this disk's export, usually equals to storage_number()
  #   - +disk_size+   -> size in Megabytes of new virtual disk
  #   - +origin+      -> originator of this request (e.g. originating agent name)
  #
  # * *Returns* :
  #   - Hash with result (:action) and additional message (:reason)
  def perform_create_disk(disk_number, disk_slot, disk_size, origin)
    return {:action => :refuse, :reason => :already_exists} if StorageNode.volume_exists?(disk_number)
    return {:action => :refuse, :reason => :not_enough_free_space} if StorageNode.free_space < disk_size

    if StorageNode.create_volume(disk_number, disk_size)
      disk = VirtualDisk.new(disk_number, disk_size)
      disk.save('cirrocumulus', origin)

      if StorageNode.add_export(disk_number, disk_slot)
        state = VirtualDiskState.find_by_disk_number(disk_number)
        state = VirtualDiskState.new(disk_number, true) unless state
        state.is_up = true
        state.save('cirrocumulus', origin)

        return {:action => :inform, :reason => :finished}
      else
        return {:action => :failure, :reason => :unable_to_add_export}
      end
    else
      return {:action => :failure, :reason => :unable_to_create_volume}
    end
  end
end

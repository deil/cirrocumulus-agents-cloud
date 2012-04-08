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
  def create_disk(disk_number, disk_slot, disk_size, origin)
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

  # Brings down export for virtual disk
  #
  # * *Args* :
  #   - +disk_number+ -> number of virtual disk
  #   - +origin+      -> originator of this request (e.g. originating agent name)
  #
  # * *Returns* :
  #   - Hash with result (:action) and additional message (:reason)
  def delete_export(disk_number, origin)
    return {:action => :refuse, :reason => :not_exists} unless StorageNode::is_exported?(disk_number)

    if StorageNode::remove_export(disk_number)
      state = VirtualDiskState.find_by_disk_number(disk_number)
      state = VirtualDiskState.new(disk_number, false) unless state
      state.is_up = false
      state.save('cirrocumulus', origin)

      return {:action => :inform, :reason => :finished}
    else
      return {:action => :failure, :reason => :unable_to_delete_export}
    end
  end

  # Deletes volume for virtual disk and all corresponding information in local database
  #
  # * *Args* :
  #   - +disk_number+ -> number of virtual disk
  #   - +origin+      -> originator of this request (e.g. originating agent name)
  #
  # * *Returns* :
  #   - Hash with result (:action) and additional message (:reason)
  def delete_volume(disk_number, origin)
    return {:action => :refuse, :reason => :not_exists} unless StorageNode::volume_exists?(disk_number)
    return {:action => :refuse, :reason => :export_exists} if StorageNode::is_exported?(disk_number)

    if StorageNode::delete_volume(disk_number)
      disk = VirtualDisk.find_by_disk_number(disk_number)
      disk.delete if disk
      state = VirtualDiskState.find_by_disk_number(disk_number)
      state.delete if state

      return {:action => :inform, :reason => :finished}
    else
      return {:action => :failure, :reason => :unable_to_delete_volume}
    end
  end

end

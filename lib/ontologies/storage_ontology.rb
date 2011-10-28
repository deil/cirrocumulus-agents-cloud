require File.join(AGENT_ROOT, 'config/storage_config.rb')
require File.join(AGENT_ROOT, 'ontologies/storage/storage_db.rb')
require "#{AGENT_ROOT}/standalone/#{Cirrocumulus::platform}/#{STORAGE_CONFIG[:backend]}/storage_node.rb"

class StorageOntology < Ontology::Base
  def initialize(agent)
    super('cirrocumulus-storage', agent)
  end

  def restore_state()
    changes_made = 0

    StorageNode.list_disks().each do |volume|
      disk = VirtualDisk.find_by_disk_number(volume)
      next if disk

      disk_size = StorageNode.volume_size(volume)
      logger.info "autodiscovered virtual disk %d with size %d Gb" % [volume, disk_size]
      disk = VirtualDisk.new(volume, disk_size)
      disk.save('discovered')
    end

    known_disks = VirtualDisk.all
    known_disks.each do |disk|
      if !StorageNode.volume_exists?(disk.disk_number)
        logger.warn "volume for disk_number %d does not exist" % [disk.disk_number]
      else
        state = VirtualDiskState.find_by_disk_number(disk.disk_number)
        export_is_up = StorageNode.is_exported?(disk.disk_number)

        if state.nil?
          logger.info "adding state record for virtual disk %d: %s" % [disk.disk_number, export_is_up]
          state = VirtualDiskState.new(disk.disk_number, export_is_up)
          state.save('discovered')
          next
        end

        export_should_be_up = state.is_up == true

        if export_should_be_up && !export_is_up
          logger.info "bringing up export #{disk.disk_number}"
          StorageNode.add_export(disk.disk_number, storage_number())
          changes_made += 1
        elsif !export_should_be_up && export_is_up
          logger.info "shutting down export #{disk.disk_number}"
          StorageNode.remove_export(disk.disk_number)
          changes_made += 1
        end

      end
    end

    logger.info "restored state, made %d changes" % [changes_made]
  end

  def handle_message(message, kb)
    case message.act
      when 'query-ref'
        msg = query(message.content)
        msg.receiver = message.sender
        msg.ontology = self.name
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)

      when 'query-if'
        msg = query_if(message.content)
        msg.receiver = message.sender
        msg.ontology = self.name
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)

      when 'request'
        handle_request(message)
    end
  end

  private

  def storage_number
    hostname = `hostname`
    if hostname =~ STORAGE_HOSTNAME_MASK
      return $1.to_i
    end

    0
  end

  def query(obj)
    msg = Cirrocumulus::Message.new(nil, 'inform', nil)

    if obj.first == :free_space
      msg.content = [:'=', obj, [StorageNode.free_space]]
    elsif obj.first == :used_space
      msg.content = [:'=', obj, [StorageNode.used_space]]
    end

    msg
  end

  def query_if(obj)
    msg = Cirrocumulus::Message.new(nil, 'inform', nil)

    if obj.first == :exists
      msg.content = handle_exists_query(obj) ? obj : [:not, obj]
    end

    msg
  end

  # (exists (.. (disk_number ..)))
  def handle_exists_query(obj)
    obj.each do |param|
      next if !param.is_a?(Array)
      if param.first.is_a?(Symbol)
        obj_type = param.first
        disk_number = nil
        param.each do |dparam|
          next if !dparam.is_a?(Array)
          if dparam.first == :disk_number
            disk_number = dparam.second.to_i
          end
        end

        if obj_type == :export
          return StorageNode::is_exported?(disk_number)
        elsif obj_type == :volume
          return StorageNode::volume_exists?(disk_number)
        end
      end
    end
  end

  def handle_request(message)
    action = message.content.first

    if action == :create
      handle_create_request(message.content.second, message)
    elsif action == :delete
      handle_delete_request(message.content.second, message)
    end
  end

  # (create (.. (disk_number ..) ..)
  def handle_create_request(obj, message)
    disk_number = disk_size = disk_slot = nil

    obj.each do |param|
      next if !param.is_a? Array
      if param.first == :disk_number
        disk_number = param.second.to_i
      elsif param.first == :size
        disk_size = param.second.to_i
      elsif param.first == :slot
        disk_slot = param.second.to_i
      end
    end

    disk_slot ||= storage_number()

    if obj.first == :volume
      perform_create_volume(disk_number, disk_size, message)
    elsif obj.first == :export
      perform_create_export(disk_number, disk_slot, message)
    elsif obj.first == :disk
      perform_create_disk(disk_number, disk_slot, disk_size, message)
    end
  end

  # (create (disk (disk_number ..) (size ..)))
  # (create (disk (disk_number ..) (size ..) (slot ..))
  def perform_create_disk(disk_number, disk_slot, disk_size, message)
    if StorageNode.volume_exists?(disk_number)
      msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:already_exists]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    elsif StorageNode.free_space < disk_size
      msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:not_enough_space]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    else # preconditions ok, try to create
      if !StorageNode.create_volume(disk_number, disk_size)
        msg = Cirrocumulus::Message.new(nil, 'failure', [message.content, [:unable_to_create_volume]])
        msg.ontology = self.name
        msg.receiver = message.sender
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)
      else
        disk = VirtualDisk.new(disk_number, disk_size)
        disk.save('cirrocumulus', message.sender)

        if !StorageNode.add_export(disk_number, disk_slot)
          msg = Cirrocumulus::Message.new(nil, 'failure', [message.content, [:unable_to_add_export]])
          msg.ontology = self.name
          msg.receiver = message.sender
          msg.in_reply_to = message.reply_with
          self.agent.send_message(msg)
        else # success
          state = VirtualDiskState.find_by_disk_number(disk_number)
          state = VirtualDiskState.new(disk_number, true) unless state
          state.is_up = true
          state.save('cirrocumulus', message.sender)

          msg = Cirrocumulus::Message.new(nil, 'inform', [message.content, [:finished]])
          msg.ontology = self.name
          msg.receiver = message.sender
          msg.in_reply_to = message.reply_with
          self.agent.send_message(msg)
        end
      end
    end
  end

  # (create (volume (disk_number ..) (size ..)))
  def perform_create_volume(disk_number, disk_size, message)
    if StorageNode::volume_exists?(disk_number)
      msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:already_exists]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
      return
    end

    if StorageNode::create_volume(disk_number, disk_size)
      disk = VirtualDisk.new(disk_number, disk_size)
      disk.save('cirrocumulus', message.sender)

      msg = Cirrocumulus::Message.new(nil, 'inform', [message.content, [:finished]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    else
      msg = Cirrocumulus::Message.new(nil, 'failure', [message.content, [:unknown_reason]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    end
  end

  # (create (export (disk_number ..)))
  # (create (export (disk_number ..) (slot ..)))
  def perform_create_export(disk_number, disk_slot, message)
    if !StorageNode::volume_exists?(disk_number)
      msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:volume_does_not_exist]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
      return
    end

    if StorageNode::is_exported?(disk_number)
      msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:already_exists]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
      return
    end

    if StorageNode::add_export(disk_number, disk_slot)
      state = VirtualDiskState.find_by_disk_number(disk_number)
      state = VirtualDiskState.new(disk_number, true) unless state
      state.is_up = true
      state.save('cirrocumulus', message.sender)

      msg = Cirrocumulus::Message.new(nil, 'inform', [message.content, [:finished]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    else
      msg = Cirrocumulus::Message.new(nil, 'failure', [message.content, [:unknown_reason]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    end
  end

  # (delete (..))
  def handle_delete_request(obj, message)
    disk_number = nil
    obj.each do |param|
      next if !param.is_a? Array
      if param.first == :disk_number
        disk_number = param.second.to_i
      end
    end

    if obj.first == :export
      perform_delete_export(disk_number, message)
    elsif obj.first == :volume
      perform_delete_volume(disk_number, message)
    end
  end

  # (delete (export (disk_number 1)))
  def perform_delete_export(disk_number, message)
    if StorageNode::remove_export(disk_number)
      state = VirtualDiskState.find_by_disk_number(disk_number)
      state = VirtualDiskState.new(disk_number, false) unless state
      state.is_up = false
      state.save('cirrocumulus', message.sender)

      msg = Cirrocumulus::Message.new(nil, 'inform', [message.content, [:finished]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    else
      msg = Cirrocumulus::Message.new(nil, 'failure', [message.content, [:unknown_reason]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    end
  end

  # (delete (volume (disk_number 1)))
  def perform_delete_volume(disk_number, message)
    if !StorageNode::volume_exists?(disk_number)
      msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:not_exists]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
      return
    end

    if StorageNode::delete_volume(disk_number)
      disk = VirtualDisk.find_by_disk_number(disk_number)
      disk.delete if disk
      state = VirtualDiskState.find_by_disk_number(disk_number)
      state.delete if state

      msg = Cirrocumulus::Message.new(nil, 'inform', [message.content, [:finished]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    else
      msg = Cirrocumulus::Message.new(nil, 'failure', [message.content, [:unknown_reason]])
      msg.ontology = self.name
      msg.receiver = message.sender
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
    end
  end

end

Log4r::Logger['agent'].info "storage backend = #{STORAGE_CONFIG[:backend]}"

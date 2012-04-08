require File.join(AGENT_ROOT, 'config/storage_config.rb')
require File.join(AGENT_ROOT, 'ontologies/storage/storage_db.rb')
require "#{AGENT_ROOT}/standalone/linux/#{STORAGE_CONFIG[:backend]}/storage_node.rb"
require File.join(AGENT_ROOT, 'ontologies/storage/hdd.rb')
require File.join(AGENT_ROOT, 'ontologies/storage/hdd_autodiscover.rb')
require File.join(AGENT_ROOT, 'ontologies/storage/storage_ruleset.rb')
require_relative 'storage/storage_worker.rb'

class StorageOntology < Ontology::Base
  def initialize(agent)
    super('cirrocumulus-storage', agent)

    logger.info "Starting StorageOntology.."
    @engine = StorageRuleset.new(self)
    @worker = StorageWorker.new
    @tick_counter = 0

    logger.info "My storage number is %d" % [storage_number()]
  end

  def restore_state()
    logger.info "Restoring previous state"
    changes_made = 0

    autodiscover_devices()
    discover_new_disks()
    changes_made += restore_exports_states()

    logger.info "State restored, made %d changes to node configuration" % [changes_made]

    all_disks_count = VirtualDisk.all.size
    total_disks_size = VirtualDisk.all.sum(&:size)/1024
    logger.info "This storage handles %d virtual disks with total size of %d Gb" % [all_disks_count, total_disks_size]
  end

  protected

  def handle_message(message, kb)
    case message.act
      when 'query-ref'
        msg             = query(message.content)
        msg.receiver    = message.sender
        msg.ontology    = self.name
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)

      when 'query-if'
        msg             = query_if(message.content)
        msg.receiver    = message.sender
        msg.ontology    = self.name
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)

      when 'request'
        handle_request(message)
    end
  end

  def handle_tick()
    if @tick_counter >= 60
      storage_info = @storage_information.collect()
      @engine.replace [:storage, :free_space, :FREE_SPACE], storage_info[:lvm][:free]
      storage_info[:hdd].each do |hdd|
        @engine.replace [:hdd, hdd.device, :sn, :SN], hdd.sn
        @engine.replace [:hdd, hdd.device, :temperature, :TEMP], hdd.temperature
        @engine.replace [:hdd, hdd.device, :health, :STATUS], hdd.health
      end

      @tick_counter = 0
    else
      @tick_counter += 1
    end
  end

  private

  def storage_number
    hostname = `hostname`
    if hostname =~ STORAGE_CONFIG[:hostname_mask]
      return $1.to_i
    end

    0
  end

  # Looks at LVM volume name and discovers underlying MD and HDD devices.
  # It also collects some critical information about storage subsystem (e.g. free space)
  def autodiscover_devices
    logger.debug "Discovering information about storage subsystem (HDD and MD devices)"
    @storage_information = HddAutodiscover.new(STORAGE_CONFIG[:volume_name])
    collected = @storage_information.collect()

    @engine.assert [:storage, :free_space, collected[:lvm][:free]]
    collected[:hdd].each do |hdd|
      @engine.assert [:hdd, hdd.device, :sn, hdd.sn]
      @engine.assert [:hdd, hdd.device, :temperature, hdd.temperature]
      @engine.assert [:hdd, hdd.device, :health, hdd.health]
    end
  end

  # Looks through storage subsystem and searches for new virtual disk volumes, not recorded in internal database
  def discover_new_disks
    logger.debug "Discovering new virtual disks."

    StorageNode.list_disks().each do |volume|
      disk = VirtualDisk.find_by_disk_number(volume)
      next if disk

      disk_size = StorageNode.volume_size(volume)
      logger.info "autodiscovered virtual disk %d with size %d Mb" % [volume, disk_size]
      disk = VirtualDisk.new(volume, disk_size)
      disk.save('discovered')
    end
  end

  # Restores states of recorded virtual disks. It can bring up or take down corresponding export!
  def restore_exports_states
    logger.debug "Restoring exports states."

    changes_made = 0
    known_disks = VirtualDisk.all

    known_disks.each do |disk|
      if !StorageNode.volume_exists?(disk.disk_number)
        logger.info "Volume for disk number %d does not exists, removing from database" % [disk.disk_number]
        state = VirtualDiskState.find_by_disk_number(disk.disk_number)
        state.delete if state
        disk.delete
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

    changes_made
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

    result = case obj.first
      when :disk
        @worker.create_disk(disk_number, disk_slot, disk_size, message.sender)
      when :volume
        @worker.create_volume(disk_number, disk_size, message.sender)
      when :export
        @worker.create_export(disk_number, disk_slot, message.sender)
    end

    msg = Cirrocumulus::Message.new(nil, result[:action], [message.content, [result[:reason]]])
    msg.ontology = self.name
    self.agent.reply_to_message(msg, message)
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

    result = case obj.first
      when :export
        @worker.delete_export(disk_number, message.sender)

      when :volume
        @worker.delete_volume(disk_number, message.sender)
    end

    msg = Cirrocumulus::Message.new(nil, result[:action], [message.content, [result[:reason]]])
    msg.ontology = self.name
    self.agent.reply_to_message(msg, message)
  end
end

Log4r::Logger['agent'].info "storage backend = #{STORAGE_CONFIG[:backend]}"

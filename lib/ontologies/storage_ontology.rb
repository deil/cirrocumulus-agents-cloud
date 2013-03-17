require 'cirrocumulus/ontology'

require_relative '../config/storage_config'
require_relative 'storage/storage_db'
require_relative 'storage/hdd'
require_relative 'storage/hdd_autodiscover'
require_relative 'storage/storage_worker.rb'

class StorageOntology < Ontology
  ontology 'storage'

  def restore_state
    @tick_counter = 0
    @worker = StorageWorker.new
    logger.info 'My storage number is %d' % storage_number

    logger.info 'Restoring previous state'
    changes_made = 0

    autodiscover_devices()
    discover_new_disks()
    changes_made += restore_exports_states()

    logger.info 'State restored, made %d changes to node configuration' % [changes_made]

    all_disks_count = VirtualDisk.all.size
    total_disks_size = VirtualDisk.all.sum(&:size)/1024
    logger.info 'This storage handles %d virtual disks with total size of %d Gb' % [all_disks_count, total_disks_size]
  end

  def tick
    super()

    @tick_counter += 1
    return if @tick_counter < 300

    storage_info = @storage_information.collect()
    replace [:storage, :free_space, :FREE_SPACE], storage_info[:lvm][:free]
    storage_info[:hdd].each do |hdd|
      replace [:hdd, hdd.device, :sn, :SN], hdd.sn
      replace [:hdd, hdd.device, :temperature, :TEMP], hdd.temperature
      replace [:hdd, hdd.device, :health, :STATUS], hdd.health
    end

    @tick_counter = 0
  end

  def handle_query(sender, expression, options = {})
    if expression == [:free_space]
      inform(sender, [expression, StorageNode.free_space])
    elsif expression == [:used_space]
      inform(sender, [expression, StorageNode.used_space])
    else
      super
    end
  end

  def handle_query_if(sender, proposition, options = {})
    data = parse_params(proposition)
    if data.has_key?(:exists)
      exists_q = data[:exists]
      if exists_q.has_key?(:volume)
        params = exists_q[:volume]
        disk_number = params[:disk_number]
        if StorageNode.volume_exists?(disk_number)
          inform(sender, proposition, reply(options))
        else
          inform(sender, [:not, proposition], reply(options))
        end
      elsif exists_q.has_key?(:export)
        params = exists_q[:volume]
        disk_number = params[:disk_number]
        if StorageNode.is_exported?(disk_number)
          inform(sender, proposition, reply(options))
        else
          inform(sender, [:not, proposition], reply(options))
        end
      end
    end

    super
  end

  def handle_request(sender, contents, options = {})
    if !handle_saga_reply(sender, :request, contents, options)
      data = parse_params(contents)

      if data.has_key?(:create)
        create_r = data[:create]
        result = {}
        if create_r.has_key?(:disk)
          params = create_r[:disk]
          disk_slot = params[:slot] || storage_number
          result = @worker.create_disk(params[:disk_number], disk_slot, params[:size], sender.to_s)
        elsif create_r.has_key?(:volume)
          params = create_r[:volume]
          result = @worker.create_volume(params[:disk_number], params[:size], sender.to_s)
        elsif create_r.has_key?(:export)
          params = create_r[:export]
          disk_slot = params[:slot] || storage_number
          result = @worker.create_export(params[:disk_number], disk_slot, sender.to_s)
        end

        action = result[:action]
        if action == :failure
          failure(sender, [contents, result[:reason]], reply(options))
        elsif action == :refuse
          refuse(sender, [contents, result[:reason]], reply(options))
        elsif action == :agree
          agree(sender, contents, reply(options))
        end

      elsif data.has_key?(:delete)
        delete_r = data[:delete]
      end
    end
  end

  protected

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
    logger.debug 'Discovering information about storage subsystem (HDD and MD devices)'
    @storage_information = HddAutodiscover.new(STORAGE_CONFIG[:volume_name])
    collected = @storage_information.collect()

    assert [:storage, :free_space, collected[:lvm][:free]]
    collected[:hdd].each do |hdd|
      assert [:hdd, hdd.device, :sn, hdd.sn]
      assert [:hdd, hdd.device, :temperature, hdd.temperature]
      assert [:hdd, hdd.device, :health, hdd.health]
    end
  end

  # Looks through storage subsystem and searches for new virtual disk volumes, not recorded in internal database
  def discover_new_disks
    logger.debug 'Discovering new virtual disks.'

    StorageNode.list_disks().each do |volume|
      disk = VirtualDisk.find_by_disk_number(volume)
      next if disk

      disk_size = StorageNode.volume_size(volume)
      logger.info 'autodiscovered virtual disk %d with size %d Mb' % [volume, disk_size]
      disk = VirtualDisk.new(volume, disk_size)
      disk.save('discovered')
    end
  end

  # Restores states of recorded virtual disks. It can bring up or take down corresponding export!
  def restore_exports_states
    logger.debug 'Restoring exports states.'

    changes_made = 0
    known_disks = VirtualDisk.all

    known_disks.each do |disk|
      if !StorageNode.volume_exists?(disk.disk_number)
        logger.info 'volume for disk number %d does not exist, removing from database' % [disk.disk_number]
        state = VirtualDiskState.find_by_disk_number(disk.disk_number)
        state.delete if state
        disk.delete
      else
        state = VirtualDiskState.find_by_disk_number(disk.disk_number)
        export_is_up = StorageNode.is_exported?(disk.disk_number)

        if state.nil?
          logger.info 'adding state record for virtual disk %d: %s' % [disk.disk_number, export_is_up]
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

  def logger
    Log4r::Logger['ontology::storage']
  end

  def parse_params(content, subroutine = false)
    return parse_params(content.size == 1 ? content[0] : content, true)  if !subroutine

    return [] if content.nil?
    return content if !content.is_a?(Array)
    return [] if content.size == 0
    return {content[0] => []} if content.size == 1
    return {content[0] => parse_params(content[1], true)} if content.size == 2

    res = {content[0] => []}

    if content.all? {|item| !item.is_a?(Array)}
      content.each_with_index do |item,i|
        if i == 0
          res[content[0]] = []
        else
          res[content[0]] << item
        end
      end
    else
      content.each_with_index do |item,i|
        if i == 0
          res[content[0]] = {}
        else
          res[content[0]].merge!(parse_params(item, true))
        end
      end
    end

    res
  end

end

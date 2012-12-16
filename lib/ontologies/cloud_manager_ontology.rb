require_relative 'cloud_manager/cloud_db-o1.rb'
require_relative 'cloud_manager/cloud_ruleset.rb'
require_relative 'cloud_manager/query_nodes_saga.rb'
require_relative 'cloud_manager/query_storages_saga.rb'
require_relative 'cloud_manager/build_virtual_disk_saga.rb'
require_relative 'cloud_manager/delete_virtual_disk_saga.rb'
require_relative 'cloud_manager/attach_virtual_disk_saga.rb'
require_relative 'cloud_manager/detach_virtual_disk_saga.rb'
require_relative 'cloud_manager/build_xen_vds_saga.rb'
require_relative 'cloud_manager/create_xen_vds_saga.rb'
require_relative 'cloud_manager/start_vds_saga.rb'
require_relative 'cloud_manager/stop_vds_saga.rb'
require_relative 'cloud_manager/query_xen_vds_state_saga.rb'
require_relative 'cloud_manager/reboot_xen_vds_saga.rb'

class CloudManagerOntology < Cirrocumulus::Ontology
  attr_reader :engine
  
  def initialize(agent)
    super('cirrocumulus-cloud', agent)
    @engine = CloudRuleset.new(self)
  end

  def restore_state()
    @engine.start()
    @engine.assert [:just_started]
  end

  def discover_nodes()
    create_saga(QueryNodesSaga).start()
  end

  def discover_storages()
    create_saga(QueryStoragesSaga).start()
  end

  def query_xen_vds_state(vds_uid)
    saga = create_saga(QueryXenVdsStateSaga)
    saga.start(vds_uid, nil)
  end

  def start_xen_vds(vds)
    saga = create_saga(StartVdsSaga)
    saga.start(vds, nil) #if vds.uid == "048f19209e9b11de8a390800200c9a66"
  end

  def stop_xen_vds(vds)
    create_saga(StopVdsSaga).start(vds, nil)
  end

  def build_xen_vds(vds)
    create_saga(BuildXenVdsSaga).start(vds)
  end

  def build_disk(disk)
    create_saga(BuildVirtualDiskSaga).start(disk)
  end
  
  def start_delete_virtual_disk_saga(disk_number)
    create_saga(DeleteVirtualDiskSaga).start(disk_number)
  end

  protected
  
  def handle_message(message, kb)
    p message

    case message.act
      when 'inform' then
        return if process_received_statistics(message.content)

        if @engine.query(message.content)
          p "@engine.query = 'true' for:"
          p message
          return
        end

        if message.content.first == :vds && message.content[2] == :state
          vds_id = message.content[1]
          @engine.replace [:vds, vds_id, :state, :STATE], message.content[3]
          return
        end

        @engine.assert message.content

      when 'query-ref' then
        msg = Cirrocumulus::Message.new(nil, 'inform', [message.content, [query_ref(message.content)]])
        msg.ontology = self.name
        self.agent.reply_to_message(msg, message)

      when 'query-if' then
        msg = query_if(message.content)
        msg.ontology = self.name
        self.agent.reply_to_message(msg, message)

      when 'request' then
        handle_request(message)
      else
        msg = Cirrocumulus::Message.new(nil, 'not-understood', [message.content, :not_supported])
        msg.ontology = self.name
        self.agent.reply_to_message(msg, message)
    end
  end

  def handle_tick()
  end

  private

  def query_ref(content)
    result = []
    params = Cirrocumulus::Message.parse_params(content)
    query = params.keys.first

    if query == :state
      object = params[query]

      if object.include? :vds
        vds_uid = object[:vds][:uid]
        vds = VpsConfiguration.find_by_uid(vds_uid)

        if vds
          matched_data = @engine.match [:vds, vds_uid, :actual_state, :STATE]
          if matched_data.empty?
            result = :unknown
          else
            vds_state = matched_data.first
            result = vds_state[:STATE]
          end
        else
          result = :vds_not_found
        end
      end
    end

    Log4r::Logger['agent'].info "Query: %s, result: %s" % [params.inspect, result]

    result
  end

  def query_if(obj)
    msg = Cirrocumulus::Message.new(nil, 'inform', nil)

    if obj.first == :running
      msg.content = handle_running_query(obj) ? obj : [:not, obj]
    end

    msg
  end
  
  # (running (vds ..))
  def handle_running_query(obj)
    guest_id = nil
    obj.each do |param|
      next if !param.is_a?(Array)
      if param.first.is_a?(Symbol) && param.first == :vds
        guest_id = param.second
      end
    end

    @engine.match([:vds, guest_id, :running_on, :NODE]).empty? ? false : true
  end

  def handle_request(message)
    params = Cirrocumulus::Message.parse_params(message.content)

    if params.is_a?(Symbol)
      if params == :dump
        @engine.dump_kb()
      end
    else
      action = params.keys.first

      if action == :reboot
        handle_reboot_request(params[action], message)
      elsif action == :create
        handle_create_request(params[action], message)
      elsif action == :delete
        handle_delete_request(params[action], message)
      elsif action == :detach
        handle_detach_request(params[action], message)
      elsif action == :attach
        handle_attach_request(params[action], message)
      end
    end
  end
  
  # (detach (disk (disk_number ..))
  def handle_detach_request(obj, original_message)
    if obj.include? :disk
      params = obj[:disk]
      disk_number = params[:disk_number]

      disk = VdsDisk.find_by_number(disk_number)
      if disk.nil?
        msg = Cirrocumulus::Message.new(nil, 'refuse', [original_message.content, [:disk_not_found]])
        msg.ontology = self.name
        self.agent.reply_to_message(msg, original_message)
        return
      end

      vdses = @engine.match [:virtual_disk, disk_number, :attached_to, :VDS, :as, :BLOCK_DEVICE]
      if vdses.empty?
        msg = Cirrocumulus::Message.new(nil, 'refuse', [original_message.content, [:already_detached]])
        msg.ontology = self.name
        self.agent.reply_to_message(msg, original_message)
        return
      end

      vds_uid = vdses.first[:VDS]

      vds = VpsConfiguration.find_by_uid(vds_uid)
      if vds.nil?
        msg = Cirrocumulus::Message.new(nil, 'refuse', [original_message.content, [:vds_not_found]])
        msg.ontology = self.name
        self.agent.reply_to_message(msg, original_message)
        return
      end

      vds.detach_disk(disk)
      create_saga(DetachVirtualDiskSaga).start(disk_number, original_message)
    end
  end
  
  # (attach (disk (disk_number ..) (vds_uid ..)))
  def handle_attach_request(obj, original_message)
    if obj.include? :disk
      params = obj[:disk]
      disk_number = params[:disk_number]
      vds_uid = params[:vds_uid]

      vds = VpsConfiguration.find_by_uid(vds_uid)
      if vds.nil?
        msg = Cirrocumulus::Message.new(nil, 'refuse', [original_message.content, [:vds_not_found]])
        msg.ontology = self.name
        self.agent.reply_to_message(msg, original_message)
        return
      end

      disk = VdsDisk.find_by_number(disk_number)
      if disk.nil?
        msg = Cirrocumulus::Message.new(nil, 'refuse', [original_message.content, [:disk_not_found]])
        msg.ontology = self.name
        self.agent.reply_to_message(msg, original_message)
        return
      end

      if vds.disks.find {|d| d.number == disk.number}
        msg = Cirrocumulus::Message.new(nil, 'refuse', [original_message.content, [:already_attached]])
        msg.ontology = self.name
        self.agent.reply_to_message(msg, original_message)
        return
      end

      vds.attach_disk(disk)
      create_saga(AttachVirtualDiskSaga).start(disk_number, vds_uid, disk.block_device, original_message)
    end
  end

  # (reboot (vds (uid ...)))
  def handle_reboot_request(obj, original_message)
    if obj.include? :vds
      vds = obj[:vds]
      vds_uid = vds[:uid]

      node = @engine.match [:vds, vds_uid, :running_on, :NODE]
      if node.empty?
        context = original_message.context()
        msg = Cirrocumulus::Message.new(nil, 'refuse', [original_message.content, [:vds_not_running]])
        msg.ontology = self.name
        msg.receiver = context.sender
        msg.in_reply_to = context.reply_with
        self.agent.send_message(msg)
      else
        saga = create_saga(RebootXenVdsSaga)
        saga.start(vds_uid, original_message)
      end
    end
  end

  # (create (vds (ram ..)))
  def handle_create_request(obj, original_message)
    if obj.include? :vds
      vds_config = obj[:vds]
      if vds_config[:type] == :xen
        saga = create_saga(CreateXenVdsSaga)
        saga.start(vds_config, original_message)
      else
        context = original_message.context()
        msg = Cirrocumulus::Message.new(nil, 'refuse', [original_message.content, [:not_supported_vds_type]])
        msg.ontology = self.name
        msg.receiver = context.sender
        msg.in_reply_to = context.reply_with
        self.agent.send_message(msg)
      end
    elsif obj.include? :disk
      disk_number = create_virtual_disk(obj[:disk])
      msg = Cirrocumulus::Message.new(nil, 'inform', [original_message.content, [:disk_number, disk_number]])
      msg.ontology = original_message.ontology
      self.agent.reply_to_message(msg, original_message)
    end
  end

  def create_virtual_disk(obj)
    disk_size = obj[:size]
    disk = VdsDisk.create(disk_size)
    @engine.assert [:virtual_disk, disk.number, :actual_state, :created]
    disk.number
  end

  def handle_delete_request(obj, original_message)
    if obj.include?(:disk)
      disk_number = obj[:disk][:disk_number]
      disk = VdsDisk.find_by_number(disk_number)

      if disk
        @engine.replace [:virtual_disk, disk_number, :state, :STATE], :inactive
        msg = Cirrocumulus::Message.new(nil, 'inform', [original_message.content, [:finished]])
      else
        msg = Cirrocumulus::Message.new(nil, 'refuse', [original_message.content, [:not_exists]])
      end

      msg.ontology = 'cirrocumulus-cloud'
      self.agent.reply_to_message(msg, original_message)
    end
  end
  
  def process_received_statistics(obj)
    params = Cirrocumulus::Message.parse_params(obj)

    return false if params[:guest].blank?
    guest = params[:guest]
    return false if guest[:uid].blank?

    stats = VdsStatistics.new(guest[:uid])

    if guest.keys.include?(:cpu_time)
      stats.store_cpu_time(guest[:cpu_time].to_f)
    end

    if guest.keys.include?(:vif)
      vif_num = guest[:vif].to_i
      tx = guest[:tx].to_i
      rx = guest[:rx].to_i

      case vif_num
        when 0
          stats.store_wan_stats(tx, rx)

        when 1
          stats.store_lan_stats(tx, rx)
      end
    end

    true
  rescue Exception => ex
    false
  end

end

require 'cirrocumulus/saga'
require File.join(AGENT_ROOT, 'ontologies/cloud_manager/cloud_db-o1.rb')
require File.join(AGENT_ROOT, 'ontologies/cloud_manager/cloud_ruleset.rb')
require File.join(AGENT_ROOT, 'ontologies/cloud_manager/build_virtual_disk_saga.rb')
require File.join(AGENT_ROOT, 'ontologies/cloud_manager/build_xen_vds_saga.rb')
require File.join(AGENT_ROOT, 'ontologies/cloud_manager/create_xen_vds_saga.rb')
require File.join(AGENT_ROOT, 'ontologies/cloud_manager/start_vds_saga.rb')
require File.join(AGENT_ROOT, 'ontologies/cloud_manager/stop_vds_saga.rb')
require File.join(AGENT_ROOT, 'ontologies/cloud_manager/query_xen_vds_state_saga.rb')

class CloudManagerOntology < Ontology::Base
  attr_reader :engine
  
  def initialize(agent)
    super('cirrocumulus-cloud', agent)
    @engine = CloudRuleset.new(self)
  end

  def restore_state()
    @engine.assert [:just_started] # TODO: need to assert any fact to initialize KB

    VpsConfiguration.active.each do |vds|
      @engine.assert [:vds, vds.uid, :state, :stopped]
      @engine.assert [:vds, vds.uid, :actual_state, :unknown]
    end

    VpsConfiguration.running.each do |vds|
      @engine.replace [:vds, vds.uid, :state, :CURRENT_STATE], :running
      #@engine.assert [:vds, vds.uid, :should_be_running] # TODO: deprecated, remove
    end

    @engine.retract [:just_started]
  end
  
  def handle_tick()
  end

  def handle_message(message, kb)
    case message.act
      when 'inform' then
        @engine.assert message.content if !@engine.query message.content

      when 'query-ref' then
        msg = Cirrocumulus::Message.new(nil, 'inform', [message.content, [query_ref(message.content)]])
        msg.receiver = message.sender
        msg.ontology = self.name
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)

      when 'query-if' then
        msg = query_if(message.content)
        msg.receiver = message.sender
        msg.ontology = self.name
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)

      when 'request' then
        handle_request(message)
      else
        msg = Cirrocumulus::Message.new(nil, 'not-understood', [message.content, :not_supported])
        msg.receiver = message.sender
        msg.ontology = self.name
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)
    end
  end

  def query_xen_vds_state(vds)
    saga = create_saga(QueryXenVdsStateSaga)
    saga.start(vds, nil)
  end
  
  def start_xen_vds(vds)
    saga = create_saga(StartVdsSaga)
    saga.start(vds, nil)
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

  private

  def query_ref(content)
    result = []
    params = Cirrocumulus::Message.parse_params(content)
    query = params.keys.first

    if query == :state
      object = params[query]
      p object

      if object.include? :vds
        vds_uid = object[:vds][:uid]
        matched_data = @engine.match [:vds, vds_uid, :actual_state, :STATE]
        if matched_data.empty?
          result = :vds_not_found
        else
          vds_state = matched_data.first
          result = vds_state[:STATE]
        end
      end
    end

    p result
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
    action = params.keys.first

    if action == :reboot
      handle_reboot_request(params[action], message)
    elsif action == :create
      handle_create_request(params[action], message)
    end
  end

  # (reboot (vds (uid ...)))
  def handle_reboot_request(obj, message)
    if obj.first == :guest
      guest_id = nil
      obj.each do |param|
        if param.is_a?(Array) && param.first == :id
          guest_id = param.second
        end
      end

      if XenNode.is_guest_running?(guest_id)
        if XenNode.reboot_guest(guest_id)
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
      else
        msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:guest_not_found]])
        msg.ontology = self.name
        msg.receiver = message.sender
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)
      end
    end
  end

  # (create (vds (ram ..)))
  def handle_create_request(obj, original_message)
    p obj

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
    end
  end

end

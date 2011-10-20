require 'cirrocumulus/saga'
require File.join(AGENT_ROOT, 'ontologies/xen/xen_ruleset.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/dom_u_kb.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/xen_db.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/xen_node.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/start_guest_saga.rb')
require File.join(AGENT_ROOT, 'standalone/mdraid.rb')
require File.join(AGENT_ROOT, 'standalone/dom_u.rb')
require File.join(AGENT_ROOT, 'standalone/mac.rb')

class XenOntology < Ontology::Base
  def initialize(agent)
    super('cirrocumulus-xen', agent)
    #@engine = XenEngine.new
  end

  def restore_state()
    #@engine.assert [:just_started]
    XenNode.set_cpu(0, 10000, 0)

    changes_made = 0
    Mdraid.list_disks().each do |discovered|
      disk = VirtualDisk.find_by_disk_number(discovered)
      next if disk

      logger.info "autodiscovered virtual disk %d" % [discovered]
      disk = VirtualDisk.new(discovered)
      disk.save('discovered')
      #@engine.assert [:virtual_disk, discovered, :active]
    end

    known_disks = VirtualDisk.all
    known_disks.each do |disk|
      if Mdraid.get_status(disk.disk_number) == :stopped
        logger.info "bringing up disk %d" % [disk.disk_number]
        changes_made += 1 if Mdraid.assemble(disk.disk_number)
      else
        #@engine.assert [:virtual_disk, disk.disk_number, :active]
      end
    end

    logger.info "restored state, made %d changes" % [changes_made]
  end
  
  def handle_tick()
    @tick_counter ||= 30 # init counter
    
    if @tick_counter == 25 # main loop
      VirtualDisk.all.each do |disk|
        #@engine.assert [:mdraid, disk.disk_number, :failed] if Mdraid.get_status(disk.disk_number) == :failed
      end
    end
    
    if @tick_counter <= 0    
      @tick_counter = 30
    else
      @tick_counter -= 1
    end
  end

  def handle_message(message, kb)
    case message.act
      when 'query-ref' then
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

      when 'request' then
        handle_request(message)
    end
  end

  private

  def query(obj)
    msg = Cirrocumulus::Message.new(nil, 'inform', nil)

    if obj.first == :free_memory
      msg.content = [:'=', obj, [XenNode.free_memory]]
    elsif obj.first == :used_memory
      msg.content = [:'=', obj, [XenNode.total_memory - XenNode.free_memory]]
    elsif obj.first == :guests_count
      msg.content = [:'=', obj, [XenNode.list_running_guests().size]]
    end

    msg
  end

  def query_if(obj)
    msg = Cirrocumulus::Message.new(nil, 'inform', nil)

    if obj.first == :running
      msg.content = handle_running_query(obj) ? obj : [:not, obj]
    end

    msg
  end

  # (running (guest ..))
  def handle_running_query(obj)
    obj.each do |param|
      next if !param.is_a?(Array)
      if param.first.is_a?(Symbol) && param.first == :guest
        guest_id = param.second
        return XenNode::is_guest_running?(guest_id)
      end
    end

    false
  end

  def handle_request(message)
    action = message.content.first

    if action == :stop
      handle_stop_request(message.content.second, message)
    elsif action == :reboot
      handle_reboot_request(message.content.second, message)
    elsif action == :start
      handle_start_request(message.content.second, message)
    end
  end

  # (stop (guest (id ..)))
  def handle_stop_request(obj, message)
    if obj.first == :guest
      guest_id = nil
      obj.each do |param|
        if param.is_a?(Array) && param.first == :id
          guest_id = param.second
        end
      end

      if XenNode.is_guest_running?(guest_id)
        if XenNode.stop_guest(guest_id)
          config = DomUConfig.find_by_name(guest_id)
          config.delete() if config

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

  # (reboot (guest (id ..)))
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

  # (start (guest (id ..) (ram ..)))
  def handle_start_request(obj, message)
    if obj.first == :guest
      guest_cfg = {:is_hvm => 0, :vcpus => 1, :cpu_cap => 0, :cpu_weight => 128, :eth => [], :disks => [], :network_boot => 0}
      guest_id = nil

      obj.each do |param|
        next if !param.is_a?(Array)
        case param.first
          when :id
            guest_id = param.second
          when :hvm
            guest_cfg[:is_hvm] = param.second.to_i
          when :ram
            guest_cfg[:ram] = param.second.to_i
          when :vcpus
            guest_cfg[:vcpus] = param.second.to_i
          when :weight
            guest_cfg[:cpu_weight] = param.second.to_i
          when :cap
            guest_cfg[:cpu_cap] = param.second.to_i
          when :vnc
            guest_cfg[:vnc_port] = param.second.to_i
          when :eth
            param.each_with_index do |eth, i|
              next if i == 0 # :eth
              guest_cfg[:eth] << eth
            end
          when :disks
            param.each do |disk|
              next if !disk.is_a?(Array)
              guest_cfg[:disks] << disk
            end
          when :network_boot
            guest_cfg[:network_boot] = param.second.to_i
        end
      end

      #p guest_id
      #p guest_cfg

      guest = DomU.new(guest_id, guest_cfg[:is_hvm] == 1 ? :hvm : :pv, guest_cfg[:ram])
      guest.vcpus = guest_cfg[:vcpus]
      guest.disks = guest_cfg[:disks]
      guest.cpu_weight = guest_cfg[:cpu_weight]
      guest.cpu_cap = guest_cfg[:cpu_cap]
      guest.eth0_mac = guest_cfg[:eth].first if guest_cfg[:eth].size > 0
      guest.eth1_mac = guest_cfg[:eth].second if guest_cfg[:eth].size > 1
      guest.network_boot = guest_cfg[:network_boot]
      guest.vnc_port = guest_cfg[:vnc_port] if guest_cfg[:vnc_port]

      saga = create_saga(StartGuestSaga)
      saga.start(guest, message)
    end
  end

end

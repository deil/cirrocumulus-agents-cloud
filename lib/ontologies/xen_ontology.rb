require 'cirrocumulus/saga'
require File.join(AGENT_ROOT, 'config/xen_config.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/xen_db.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/xen_ruleset.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/xen_node.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/start_guest_saga.rb')
require_relative 'xen/mdraid.rb'
require File.join(AGENT_ROOT, 'standalone/dom_u.rb')
require File.join(AGENT_ROOT, 'standalone/mac.rb')

class XenOntology < Ontology::Base
  def initialize(agent)
    super('cirrocumulus-xen', agent)
    logger.info "Starting XenOntology.."
    @engine = XenRuleset.new(self)
    @tick_counter = 0
  end

  def restore_state()
    logger.info "Restoring previous state"
    @engine.assert [:just_started]

    discover_new_disks()
    changes_made = shut_all_disks_down()

    logger.info "State restored, made %d changes to node configuration" % [changes_made]
  end

  protected
  
  def handle_message(message, kb)
    case message.act
      when 'inform' then
        @engine.assert message.content if !@engine.query message.content

      when 'query-ref' then
        msg = query(message.content)
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
    return

    @tick_counter ||= 60 # init counter

    if @tick_counter == 55 # main loop
      VirtualDisk.all.each do |disk|
        #@engine.assert [:mdraid, disk.disk_number, :failed] if Mdraid.get_status(disk.disk_number) == :failed
      end

      known_guests = DomUConfig.all.map {|domu| domu.name}
      running_guests = XenNode.list_running_guests()

      known_guests.each do |guest|
        if !running_guests.include? guest
          @engine.assert [:guest, guest, :just_powered_off] if (@engine.query([:guest, guest, :running]) || !@engine.query([:guest, guest, :powered_off]))
        else
          @engine.assert [:guest, guest, :just_powered_on] if @engine.query([:guest, guest, :powered_off])
        end
      end

=begin
      running_guests.each do |guest|
        if !known_guests.include? guest
          @engine.assert [:guest, guest, :just_powered_on] if @engine.query([:guest, guest, :powered_off])
        end
      end
=end
    end

    if @tick_counter <= 0
      @tick_counter = 60
    else
      @tick_counter -= 1
    end
  end

  def discover_new_disks()
    logger.debug "Discovering running MD devices"

    Mdraid.list_disks().each do |discovered|
      disk = VirtualDisk.find_by_disk_number(discovered)
      next if disk

      logger.info "autodiscovered virtual disk %d" % [discovered]
      disk = VirtualDisk.new(discovered)
      disk.save('discovered')
      #@engine.assert [:virtual_disk, discovered, :active]
    end
  end

  def shut_all_disks_down()
    changes_made = 0

    VirtualDisk.all.each do |disk|
      if Mdraid.get_status(disk.disk_number) == :active
        logger.info "shutting down disk %d" % [disk.disk_number]
        changes_made += 1 if Mdraid.stop(disk.disk_number)
      end
    end

    changes_made
  end

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
    elsif obj.first == :active
      msg.content = handle_active_query(obj) ? obj : [:not, obj]
    end

    msg
  end
  
  # (active (disk (disk_number ..)))
  def handle_active_query(obj)
    obj.each do |p|
      next if !p.is_a?(Array)
      if p.first == :disk
        disk_number = nil
        param = p.second
        if param.is_a?(Array) && param.first == :disk_number
          disk_number = param.second.to_i
        end
        
        return Mdraid.get_status(disk_number) == :active
      end
    end
    
    false
  end

  # (running (guest ..))
  def handle_running_query(obj)
    params = Cirrocumulus::Message.parse_params(obj)

    return false if params[:running].blank?
    return XenNode::is_guest_running?(params[:running][:guest])
  end

  def handle_request(message)
    action = message.content.first

    if action == :stop
      handle_stop_request(message.content.second, message)
    elsif action == :reboot
      handle_reboot_request(message.content.second, message)
    elsif action == :start
      handle_start_request(message.content.second, message)
    elsif action == :create
      handle_create_request(message.content.second, message)
    else
      msg = Cirrocumulus::Message.new(nil, 'not-understood', [message.content, :action_not_supported])
      msg.receiver = message.sender
      msg.ontology = self.name
      msg.in_reply_to = message.reply_with
      self.agent.send_message(msg)
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
    elsif obj.first == :disk
      disk_number = nil
      obj.each do |param|
        if param.is_a?(Array) && param.first == :disk_number
          disk_number = param.second.to_i
        end
      end

      disk = VirtualDisk.find_by_disk_number(disk_number)
      if disk
        if Mdraid.stop(disk_number)
          disk.delete()

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
        msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:disk_not_found]])
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
      guest.ethernets = guest_cfg[:eth]
      guest.ethernets << '' if guest.ethernets.empty?
      guest.network_boot = guest_cfg[:network_boot]
      guest.vnc_port = guest_cfg[:vnc_port] if guest_cfg[:vnc_port]

      saga = create_saga(StartGuestSaga)
      saga.start(guest, message)
    elsif obj.first == :disk
      disk_number = nil
      obj.each do |param|
        if param.is_a?(Array) && param.first == :disk_number
          disk_number = param.second.to_i
        end
      end

      if Mdraid.get_status(disk_number) == :stopped
        disk = VirtualDisk.find_by_disk_number(disk_number)
        if disk
          logger.warn("locally stored config for virtual disk '#{disk_number}' already exists! deleted")
          disk.delete()
        end

        if Mdraid.check_aoe(disk_number).size == 0
          msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:no_visible_exports]])
          msg.ontology = self.name
          msg.receiver = message.sender
          msg.in_reply_to = message.reply_with
          self.agent.send_message(msg)
        else
          if Mdraid.assemble(disk_number)
            disk = VirtualDisk.new(disk_number)
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
      else
        msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:already_exists]])
        msg.ontology = self.name
        msg.receiver = message.sender
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)
      end
    end
  end

  def handle_create_request(obj, message)
    if obj.first == :disk
      disk_number = nil
      obj.each do |param|
        if param.is_a?(Array) && param.first == :disk_number
          disk_number = param.second.to_i
        end
      end

      if Mdraid.get_status(disk_number) == :stopped
        disk = VirtualDisk.find_by_disk_number(disk_number)
        if disk
          logger.warn("locally stored config for virtual disk '#{disk_number}' already exists! deleted")
          disk.delete()
        end

        if Mdraid.check_aoe(disk_number).size == 0
          msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:no_visible_exports]])
          msg.ontology = self.name
          msg.receiver = message.sender
          msg.in_reply_to = message.reply_with
          self.agent.send_message(msg)
        else
          if Mdraid.create(disk_number)
            disk = VirtualDisk.new(disk_number)
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
      else
        msg = Cirrocumulus::Message.new(nil, 'refuse', [message.content, [:already_exists]])
        msg.ontology = self.name
        msg.receiver = message.sender
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)
      end
    end
  end

end

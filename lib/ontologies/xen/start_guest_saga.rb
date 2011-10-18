class StartGuestSaga < Saga
  attr_reader :guest

  def start(guest, message)
    @context = message.context
    @message = message
    @guest = guest

    Log4r::Logger['agent'].info "[#{id}] attempting to start guest #{guest.name}"
    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START
        check_preconditions()
    end
  end

  private

  def check_preconditions()
    if !XenNode.is_guest_running?(self.guest.name)
      if XenNode.free_memory >= self.guest.ram

        config = DomUConfig.find_by_name(self.guest.name)
        if config
          logger.warn("locally stored config for guest '#{self.guest.name}' already exists! deleted")
          config.delete()
        end

=begin
        if XenNode.start_guest(guest) && XenNode.is_guest_running?(guest_id)
          config = DomUConfig.new(guest_id)
          config.is_hvm = guest_cfg[:is_hvm]
          config.ram = guest_cfg[:ram]
          config.vcpus = guest_cfg[:vcpus]
          config.cpu_weight = guest_cfg[:cpu_weight]
          config.cpu_cap = guest_cfg[:cpu_cap]
          config.disks = guest_cfg[:disks]
          config.eth0_mac = guest_cfg[:eth0_mac]
          config.eth1_mac = guest_cfg[:eth1_mac]
          config.vnc_port = guest_cfg[:vnc_port]
          config.boot_device = guest_cfg[:network_boot] == 1 ? 'network' : 'hd'
          config.save('cirrocumulus', message.sender)

          notify_finished()
        else
          notify_failure(:unknown_reason)
        end
=end
      else
        notify_refused(:not_enough_ram)
      end
    else
      notify_refused(:guest_already_running)
    end

    finish()
  end

  def notify_failure(reason)
    msg = Cirrocumulus::Message.new(nil, 'failure', [@message.content, [reason]])
    msg.ontology = @ontology.name
    msg.receiver = @context.sender
    msg.in_reply_to = @context.reply_with
    @ontology.agent.send_message(msg)  end

  def notify_refused(reason)
    msg = Cirrocumulus::Message.new(nil, 'refuse', [@message.content, [reason]])
    msg.ontology = @ontology.name
    msg.receiver = @context.sender
    msg.in_reply_to = @context.reply_with
    @ontology.agent.send_message(msg)
  end

  def notify_finished()
    msg = Cirrocumulus::Message.new(nil, 'inform', [@message.content, [:finished]])
    msg.ontology = @ontology.name
    msg.receiver = @context.sender
    msg.in_reply_to = @context.reply_with
    @ontology.agent.send_message(msg)
  end

end

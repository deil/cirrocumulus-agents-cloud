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
          Log4r::Logger['agent'].warn("locally stored config for guest '#{self.guest.name}' already exists! deleted")
          config.delete()
        end

        if guest.disks.all? {|disk_cfg| Mdraid.get_status(disk_cfg.second) == :active}
          if XenNode.start_guest(guest) && XenNode.is_guest_running?(guest.name)
            config = DomUConfig.new(guest.name)
            config.is_hvm = guest.type == :hvm
            config.ram = guest.ram
            config.vcpus = guest.vcpus
            config.cpu_weight = guest.cpu_weight
            config.cpu_cap = guest.cpu_cap
            config.disks = guest.disks
            config.ethernets = guest.ethernets
            config.vnc_port = guest.vnc_port
            config.boot_device = guest.network_boot == 1 ? 'network' : 'hd'
            config.save('cirrocumulus', @message.sender)

            @ontology.engine.retract [:guest, guest.name, :powered_off]
            @ontology.engine.assert [:guest, guest.name, :running]
            notify_finished()
          else
            notify_failure(:unknown_reason)
          end
        else
          notify_failure(:not_all_disks_active)
        end
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

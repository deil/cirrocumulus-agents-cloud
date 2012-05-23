class RebootXenVdsSaga < Saga
  STATE_WAITING_FOR_REPLY = 1

  attr_reader :vds_uid

  def start(vds_uid, original_message)
    @vds_uid = vds_uid
    @original_message = original_message

    Log4r::Logger['agent'].info "[#{id}] Rebooting Xen VDS #{vds_uid}"
    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START
        node = @ontology.engine.match [:vds, vds_uid, :running_on, :NODE]
        node_name = node.first[:NODE]

        msg = Cirrocumulus::Message.new(nil, 'request', [:reboot, [:guest, [:id, vds_uid]]])
        msg.ontology = 'cirrocumulus-xen'
        msg.receiver = node_name
        msg.conversation_id = id
        @ontology.agent.send_message(msg)
        set_timeout(DEFAULT_TIMEOUT)
        change_state(STATE_WAITING_FOR_REPLY)

      when STATE_WAITING_FOR_REPLY
        if message
          context = @original_message.context()
          msg = Cirrocumulus::Message.new(nil, 'inform', [@original_message.content, [:finished]])
          msg.ontology = @ontology.name
          msg.receiver = context.sender
          msg.in_reply_to = context.reply_with
          msg.conversation_id = context.conversation_id
          @ontology.agent.send_message(msg)

          finish()
        else
          notify_failure(:guest_reboot_timeout)
          error()
        end
    end
  end

  protected

  def notify_failure(reason)
    Log4r::Logger['agent'].warn "[#{id}] failure: #{reason}"
    return unless @message

    context = @original_message.context()
    msg = Cirrocumulus::Message.new(nil, 'failure', [@original_message.content, [reason]])
    msg.ontology = @ontology.name
    msg.receiver = context.sender
    msg.in_reply_to = context.reply_with
    msg.conversation_id = context.conversation_id
    @ontology.agent.send_message(msg)
  end
end

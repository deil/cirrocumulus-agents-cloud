class StartGuestSaga < Saga
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
        notify_finished()
        finish()
    end
  end

  private

  def notify_finished()
    msg = Cirrocumulus::Message.new(nil, 'inform', [@message.content, [:finished]])
    msg.ontology = @ontology.name
    msg.receiver = @context.sender
    msg.in_reply_to = @context.reply_with
    @ontology.agent.send_message(msg)
  end

end

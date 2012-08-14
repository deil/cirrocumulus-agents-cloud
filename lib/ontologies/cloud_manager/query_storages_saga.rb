# Discover all active storages
class QueryStoragesSaga < Saga
  STATE_WAITING_FOR_REPLY = 1

  def start()
    Log4r::Logger['kb'].info "++ Starting saga #{id}: Discover active storages"
    @ontology.engine.assert [:storages, :discovering]
    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START
        msg = Cirrocumulus::Message.new(nil, 'query-ref', [:free_space])
        msg.ontology = 'cirrocumulus-storage'
        msg.reply_with = self.id
        @ontology.agent.send_message(msg)
        change_state(STATE_WAITING_FOR_REPLY)
        set_timeout(LONG_TIMEOUT)

      when STATE_WAITING_FOR_REPLY
        if message
          Log4r::Logger['kb'].info "Storage #{message.sender} is online."
          @ontology.engine.assert [:storage, message.sender, :state, :online]
        else
          @ontology.engine.replace [:storages, :DISCOVERING], :discovered
          finish()
        end
    end
  end
end

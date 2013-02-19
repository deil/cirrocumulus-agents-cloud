# Query VDS state.
# Saga implementing discovery of VDS state. Sends a query to all nodes and processes their replies.
class QueryXenVdsStateSaga < Saga
  STATE_WAITING_FOR_REPLY = 2

  attr_reader :vds_uid

  # Start this saga. Must pass an UID of requested VDS
  def start(vds_uid, message)
    @vds_uid = vds_uid
    @message = message

    Log4r::Logger['ontology::cloud'].info "++ Starting saga #{id}: Query VDS #{vds_uid} state"
    @ontology.replace [:vds, vds_uid, :actual_state, :STATE], :querying

    query_all_nodes
    timeout(60)
    change_state(STATE_WAITING_FOR_REPLY)
  end

  def handle_reply(sender, contents, options = {})
  end

  def handle(message = nil)
    case @state
      when STATE_START then
        msg = Cirrocumulus::Message.new(nil, 'query-if', [:running, [:guest, self.vds_uid]]) # TODO: should be query-ref
        msg.ontology = 'cirrocumulus-xen'
        msg.reply_with = id
        @ontology.agent.send_message(msg)
        set_timeout(LONG_TIMEOUT)
        change_state(STATE_WAITING_FOR_REPLY)

      when STATE_WAITING_FOR_REPLY
        if message
          data = Cirrocumulus::Message.parse_params(message.content)
          unless data[:running].blank?
            vds_uid = data[:running][:guest]
            if vds_uid != self.vds_uid
              error()
            else
              running_on = message.sender
              Log4r::Logger['kb'].info "=> VDS #{self.vds_uid} is running on #{running_on}"
              @ontology.engine.assert [:vds, self.vds_uid, :running_on, running_on]
              @ontology.engine.replace [:vds, self.vds_uid, :actual_state, :STATE], :running
              finish()
            end
          end
        else
          Log4r::Logger['kb'].info "=> VDS #{self.vds_uid} is stopped"
          @ontology.engine.replace [:vds, self.vds_uid, :actual_state, :STATE], :stopped
          finish()
        end
    end
  end

  private

  def query_all_nodes
    query_if(Agent.all, [:running, [:guest, self.vds_uid]], :ontology => 'hypervisor')
  end

end

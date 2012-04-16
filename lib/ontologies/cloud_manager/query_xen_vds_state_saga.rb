class QueryXenVdsStateSaga < Saga
  STATE_WAITING_FOR_REPLY = 2

  attr_reader :vds

  def start(vds, message)
    @vds = vds
    @message = message

    Log4r::Logger['agent'].info "[#{id}] Querying Xen VDS #{vds.uid} (#{vds.id}) state"
    @ontology.engine.replace [:vds, vds.uid, :actual_state, :STATE], :querying
    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START then
        msg = Cirrocumulus::Message.new(nil, 'query-if', [:running, [:guest, vds.uid]]) # TODO: should be query-ref
        msg.ontology = 'cirrocumulus-xen'
        msg.reply_with = id
        @ontology.agent.send_message(msg)
        set_timeout(DEFAULT_TIMEOUT)
        change_state(STATE_WAITING_FOR_REPLY)

      when STATE_WAITING_FOR_REPLY
        if message
          data = Cirrocumulus::Message.parse_params(message.content)
          unless data[:running].blank?
            vds_uid = data[:running][:guest]
            if vds_uid != vds.uid
              error()
            else
              running_on = message.sender
              @ontology.engine.assert [:vds, vds.uid, :running_on, running_on]
              @ontology.engine.replace [:vds, vds.uid, :actual_state, :STATE], :running
              finish()
            end
          end
        else
          @ontology.engine.replace [:vds, vds.uid, :actual_state, :STATE], :stopped
          finish()
        end
    end
  end
end

require File.join(AGENT_ROOT, 'standalone/mac.rb')

class StopVdsSaga < Saga
  STATE_SEARCHING_FOR_GUEST = 1
  STATE_SELECTING_HOST = 2
  STATE_CHECKING_VIRTUAL_DISKS = 3
  STATE_ACTIVATING_VIRTUAL_DISKS = 4
  STATE_STOPPING_GUEST = 5
  STATE_WAITING_FOR_POWEROFF = 6

  attr_reader :vds
  
  def start(vds, message)
    @vds = vds
    @message = message
    
    Log4r::Logger['agent'].info "[#{id}] Stopping VDS #{vds.uid} (#{vds.id})"
    @ontology.engine.replace [:vds, vds.uid, :actual_state, :RUNNING], :stopping
    handle()
  end
  
  def handle(message = nil)
    case @state
      when STATE_START
        matched_node = @ontology.engine.match [:vds, vds.uid, :running_on, :NODE]
        if !matched_node.empty?
          @target_node = matched_node.first[:NODE]
          change_state(STATE_STOPPING_GUEST)
          set_timeout(1)
        else
          failure(:not_enough_knowledge)
          error()

          msg = Cirrocumulus::Message.new(nil, 'query-if', [:running, [:guest, vds.uid]])
          msg.ontology = 'cirrocumulus-xen'
          msg.reply_with = @id
          @ontology.agent.send_message(msg)
          change_state(STATE_SEARCHING_FOR_GUEST)
          set_timeout(LONG_TIMEOUT)
        end
        
      when STATE_SEARCHING_FOR_GUEST
        if message.nil?
          error()
        else
          reply = message.content.first
          if reply == :running
            clear_timeout()
            Log4r::Logger['agent'].info "[#{id}] VDS #{vds.uid} is already running on #{message.sender}"
            @ontology.engine.assert [:vds, vds.uid, :running_on, message.sender]
            @ontology.engine.retract [:vds, vds.uid, :starting]
            notify_refused(:already_running)
            finish()
          elsif reply == :not
            # just ignore
          end
        end
        
      when STATE_STOPPING_GUEST
          msg = Cirrocumulus::Message.new(nil, 'request', [:stop, [:guest, [:id, vds.uid]]])
          msg.ontology = 'cirrocumulus-xen'
          msg.receiver = @target_node
          msg.reply_with = @id
          @ontology.agent.send_message(msg)
          change_state(STATE_WAITING_FOR_POWEROFF)
          set_timeout(DEFAULT_TIMEOUT)

      when STATE_WAITING_FOR_POWEROFF
        if message
          if message.act == 'inform' && message.content.last[0] == :finished
            @ontology.engine.replace [:vds, vds.uid, :actual_state, :CURRENT_STATE], :stopped
            Log4r::Logger['agent'].info "[#{id}] Xen VDS #{vds.uid} (#{vds.id}) has been successfully stopped"
            finish()
          else
            notify_failure(:unhandled_reply)
            error()
          end
        else
          notify_failure(:guest_poweroff_timeout)
          error()
        end
    end
  end

  protected

  def notify_refused(reason)
    Log4r::Logger['agent'].info "[#{id}] refuse: #{reason}"
    return unless @message

    msg = Cirrocumulus::Message.new(nil, 'refuse', [@message.content, [reason]])
    msg.ontology = @ontology.name
    msg.receiver = @context.sender
    msg.in_reply_to = @context.reply_with
    @ontology.agent.send_message(msg)
  end

  def notify_failure(reason)
    Log4r::Logger['agent'].warn "[#{id}] failure: #{reason}"
    return unless @message

    msg = Cirrocumulus::Message.new(nil, 'failure', [@message.content, [reason]])
    msg.ontology = @ontology.name
    msg.receiver = @context.sender
    msg.in_reply_to = @context.reply_with
    @ontology.agent.send_message(msg)
  end

end

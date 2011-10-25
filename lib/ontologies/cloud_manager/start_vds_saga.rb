require 'cirrocumulus/saga'

class StartVdsSaga < Saga
  STATE_SEARCHING_FOR_GUEST = 1
  STATE_SELECTING_HOST = 2

  attr_reader :vds
  
  def start(vds, message)
    @vds = vds
    @message = message
    
    Log4r::Logger['agent'].info "[#{id}] Starting VDS #{vds.vps_id} (#{vds.id}) with RAM=#{vds.current.ram}Mb"
    handle()
  end
  
  def handle(message = nil)
    case @state
      when STATE_START
        msg = Cirrocumulus::Message.new(nil, 'query-if', [:running, [:guest, vds.vps_id]])
        msg.ontology = 'cirrocumulus-xen'
        msg.reply_with = @id
        @ontology.agent.send_message(msg)
        change_state(STATE_SEARCHING_FOR_GUEST)
        
      when STATE_SEARCHING_FOR_GUEST
        reply = message.content.first
        if reply == :running
          notify_refused(:already_running)
          finish()
        elsif reply == :not
          msg = Cirrocumulus::Message.new(nil, 'query-ref', [:free_memory])
          msg.ontology = 'cirrocumulus-xen'
          msg.reply_with = @id
          @ontology.agent.send_message(msg)
          @hosts = []
          change_state(STATE_SELECTING_HOST)
          set_timeout(LONG_TIMEOUT)
        end

      when STATE_SELECTING_HOST
        if message.nil? # timeout
          Log4r::Logger['agent'].info "[#{id}] Found host nodes: %s" % @hosts.inspect
          finish()
        else
          if message.content.first == :"=" && message.content[1].first == :free_memory
            @hosts << {:agent => message.sender, :free_memory => message.content[2].first.to_i}
          end
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

end

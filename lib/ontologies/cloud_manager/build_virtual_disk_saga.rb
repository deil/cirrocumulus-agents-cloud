class BuildVirtualDiskSaga < Saga
  STATE_CREATING_VOLUME = 1
  STATE_SELECTING_HOST = 2
  STATE_CREATING_DISK = 3

  attr_reader :disk

  def start(disk, message = nil)
    @disk = disk
    @ontology.engine.replace [:virtual_disk, self.disk.number, :actual_state, :NEED_TO_BUILD], :building

    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START then
        Log4r::Logger['agent'].info "[#{id}] Building Virtual Disk #{disk.number}"
        msg = Cirrocumulus::Message.new(nil, 'request', [:create, [:disk, [:disk_number, disk.number], [:size, disk.size]]])
        msg.ontology = 'cirrocumulus-storage'
        msg.conversation_id = @id
        @ontology.agent.send_message(msg)
        @storages_replied = []
        change_state(STATE_CREATING_VOLUME)
        set_timeout(LONG_TIMEOUT)

      when STATE_CREATING_VOLUME
        if message.nil?
          if @storages_replied.size < 2
            Log4r::Logger['agent'].warn "[#{id}] Building Virtual Disk #{disk.number} failed: not all storages replied"
            notify_failure(:not_all_storages_replied)
            error()
          end
        else
          if message.act == 'inform' && message.content.last[0] == :finished
            @storages_replied << message.sender
          end

          if @storages_replied.size == 2
            msg = Cirrocumulus::Message.new(nil, 'query-ref', [:free_memory])
            msg.ontology = 'cirrocumulus-xen'
            msg.conversation_id = @id
            @ontology.agent.send_message(msg)
            @hosts = []

            change_state(STATE_SELECTING_HOST)
            set_timeout(DEFAULT_TIMEOUT)
          end
        end

      when STATE_SELECTING_HOST
        if message.nil? # timeout
          Log4r::Logger['agent'].info "[#{id}] Found host nodes: %s" % @hosts.inspect
          sorted_hosts = @hosts.sort {|a,b| b[:free_memory] <=> a[:free_memory]}

          unless sorted_hosts.empty?
            @selected_host = sorted_hosts.first
            @selected_host[:attempted] = true
            @selected_host[:failed] = false
            Log4r::Logger['agent'].info "[#{id}] Will try #{@selected_host[:agent]}"

            msg = Cirrocumulus::Message.new(nil, 'request', [:create, [:disk, [:disk_number, disk.number]]])
            msg.ontology = 'cirrocumulus-xen'
            msg.receiver = @selected_host[:agent]
            msg.conversation_id = @id
            @ontology.agent.send_message(msg)
            change_state(STATE_CREATING_DISK)
            set_timeout(DEFAULT_TIMEOUT)
          else
            notify_failure(:build_failed)
            error()
            @ontology.engine.replace [:virtual_disk, disk.number, :actual_state, :BUILDING], :failed_to_build
          end
        else
          if message.content.first == :"=" && message.content[1].first == :free_memory
            @hosts << {:agent => message.sender, :free_memory => message.content[2].first.to_i, :attempted => false, :failed => false}
          end
        end

      when STATE_CREATING_DISK
        if message.nil?
          Log4r::Logger['agent'].info "[#{id}] Virtual disk #{disk.number} was built successfully"
          error()
        else
          if message.sender == @selected_host[:agent] && message.act == 'inform' && message.content.last[0] == :finished
            finish()
            @ontology.engine.replace [:virtual_disk, disk.number, :actual_state, :BUILDING], :clean
          elsif message.sender == @selected_host[:agent]
            @selected_host[:failed] = true
            notify_failure(:build_failed)
            error()
            @ontology.engine.replace [:virtual_disk, disk.number, :actual_state, :BUILDING], :failed_to_build
          end
        end

    end
  end

  protected

  def notify_failure(reason)
    Log4r::Logger['agent'].warn "[#{id}] failure: #{reason}"
    return unless @message

    msg = Cirrocumulus::Message.new(nil, 'failure', [@message.content, [reason]])
    msg.ontology = @ontology.name
    msg.receiver = @context.sender
    msg.in_reply_to = @context.reply_with
    msg.conversation_id = @context.conversation_id
    @ontology.agent.send_message(msg)
  end

end

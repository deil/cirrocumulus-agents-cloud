require File.join(AGENT_ROOT, 'standalone/mac.rb')

class StartVdsSaga < Saga
  STATE_SEARCHING_FOR_GUEST = 1
  STATE_SELECTING_HOST = 2
  STATE_CHECKING_VIRTUAL_DISKS = 3
  STATE_ACTIVATING_VIRTUAL_DISKS = 4
  STATE_STARTING_GUEST = 5
  STATE_WAITING_FOR_GUEST = 6

  attr_reader :vds
  
  def start(vds, message)
    @vds = vds
    @message = message
    
    Log4r::Logger['agent'].info "[#{id}] Starting VDS #{vds.uid} (#{vds.id}) with RAM=#{vds.current.ram}Mb"
    @ontology.engine.replace [:vds, vds.uid, :actual_state, :STOPPED], :starting
    handle()
  end
  
  def handle(message = nil)
    case @state
      when STATE_START
        msg = Cirrocumulus::Message.new(nil, 'query-if', [:running, [:guest, vds.uid]])
        msg.ontology = 'cirrocumulus-xen'
        msg.reply_with = @id
        @ontology.agent.send_message(msg)
        change_state(STATE_SEARCHING_FOR_GUEST) # TODO: actually, we do not need this
        set_timeout(DEFAULT_TIMEOUT)
        
      when STATE_SEARCHING_FOR_GUEST
        if message.nil?
          msg = Cirrocumulus::Message.new(nil, 'query-ref', [:free_memory])
          msg.ontology = 'cirrocumulus-xen'
          msg.reply_with = @id
          @ontology.agent.send_message(msg)
          @hosts = []
          change_state(STATE_SELECTING_HOST)
          set_timeout(DEFAULT_TIMEOUT)
        else
          reply = message.content.first
          if reply == :running
            clear_timeout()
            Log4r::Logger['agent'].warn "[#{id}] VDS #{vds.uid} is already running on #{message.sender}"
            @ontology.engine.assert [:vds, vds.uid, :running_on, message.sender]
            @ontology.engine.retract [:vds, vds.uid, :starting]
            notify_refused(:already_running)
            finish()
          elsif reply == :not
            # just ignore
          end
        end

      when STATE_SELECTING_HOST
        if message.nil? # timeout
          #Log4r::Logger['agent'].info "[#{id}] Found host nodes: %s" % @hosts.inspect
          sorted_hosts = @hosts.sort {|a,b| b[:free_memory] <=> a[:free_memory]}
          @selected_host = sorted_hosts.first
          @selected_host[:attempted] = true
          @selected_host[:failed] = false
          Log4r::Logger['agent'].info "[#{id}] Will try #{@selected_host[:agent]} (#{@selected_host[:free_memory]}Mb RAM available, #{vds.current.ram}Mb needed)"
          @virtual_disk_states = vds.disks.map {|disk| {:disk => disk, :active => false}}
          vds.disks.each do |disk|
            msg = Cirrocumulus::Message.new(nil, 'query-if', [:active, [:disk, [:disk_number, disk.number]]])
            msg.receiver = @selected_host[:agent]
            msg.ontology = 'cirrocumulus-xen'
            msg.reply_with = id
            @ontology.agent.send_message(msg)
          end
          change_state(STATE_CHECKING_VIRTUAL_DISKS)
          set_timeout(DEFAULT_TIMEOUT)
        else
          if message.content.first == :"=" && message.content[1].first == :free_memory
            @hosts << {:agent => message.sender, :free_memory => message.content[2].first.to_i, :attempted => false, :failed => false}
          end
        end

      when STATE_CHECKING_VIRTUAL_DISKS
        if message
          if message.content.first == :active
            disk_number = message.content[1][1][1].to_i
            @virtual_disk_states.each do |disk|
              next if disk[:disk].number != disk_number
              disk[:active] = true
              Log4r::Logger['agent'].info "[#{id}] Virtual disk #{disk[:disk].number} is already active"
              @ontology.engine.assert [:virtual_disk, disk[:disk].number, :active_on, @selected_host[:agent]]
            end
          end
        else
          if @virtual_disk_states.all? {|disk_state| disk_state[:active] == true}
            change_state(STATE_STARTING_GUEST)
            set_timeout(1)
          else
            @need_to_activate = @virtual_disk_states.select {|disk_state| disk_state[:active] == false}
            @need_to_activate.each do |disk_state|
              Log4r::Logger['agent'].info "[#{id}] Activating virtual disk #{disk_state[:disk].disk_number}.."
              msg = Cirrocumulus::Message.new(nil, 'request', [:stop, [:disk, [:disk_number, disk_state[:disk].number]]])
              msg.ontology = 'cirrocumulus-xen'
              msg.reply_with = 'ignored'
              @ontology.agent.send_message(msg)

              msg = Cirrocumulus::Message.new(nil, 'request', [:start, [:disk, [:disk_number, disk_state[:disk].number]]])
              msg.ontology = 'cirrocumulus-xen'
              msg.receiver = @selected_host[:agent]
              msg.reply_with = id
              @ontology.agent.send_message(msg)
            end

            change_state(STATE_ACTIVATING_VIRTUAL_DISKS)
            set_timeout(DEFAULT_TIMEOUT)
          end
        end

      when STATE_ACTIVATING_VIRTUAL_DISKS
        if message
          if message.act == 'inform' && message.content[0].first == :start
            # (start (disk (disk_number ..))) (finished)
            disk_number = message.content[0][1][1][1].to_i
            @need_to_activate.each do |disk_state|
              if disk_state[:disk].disk_number == disk_number
                disk_state[:active] = true
                @ontology.engine.assert [:virtual_disk, disk_state[:disk].disk_number, :active_on, message.sender]
              end
            end
          end
        else
          if @need_to_activate.all? {|disk_state| disk_state[:active] == true}
            change_state(STATE_STARTING_GUEST)
            set_timeout(1)
          else
            notify_failure(:unable_to_activate_disks)
            error()
          end
        end

      when STATE_STARTING_GUEST
        guest_parameters = [
            :guest,
            [:id, vds.uid],
            [:hvm, vds.hvm? ? 1 : 0],
            [:ram, vds.current.ram],
            [:vcpus, 1],
            [:weight, vds.current.ram],
            [:cap, 0],
            [:vnc, 5900 + vds.id],
            [:network_boot, 0],
            [:eth, MAC.generate(1, vds.id, 0), MAC.generate(1, vds.id, 1)]
        ]

        disks = vds.disks.map {|disk| [disk.block_device, disk.number]}
        guest_parameters << [:disks] + disks

        msg = Cirrocumulus::Message.new(nil, 'request', [:start, guest_parameters])
        msg.ontology = 'cirrocumulus-xen'
        msg.receiver = @selected_host[:agent]
        msg.reply_with = id
        @ontology.agent.send_message(msg)

        change_state(STATE_WAITING_FOR_GUEST)
        set_timeout(LONG_TIMEOUT)
        
      when STATE_WAITING_FOR_GUEST
        if message
          if message.act == 'inform' && message.content.last[0] == :finished
            @ontology.engine.retract [:guest, vds.uid, :powered_off], true
            @ontology.engine.replace [:vds, vds.uid, :actual_state, :CURRENT_STATE], :running
            @ontology.engine.assert [:vds, vds.uid, :running_on, message.sender]
            @selected_host[:failed] = false
            Log4r::Logger['agent'].info "[#{id}] Xen VDS #{vds.uid} (#{vds.id}) has been successfully started on #{message.sender}"
            finish()
          else
            @selected_host[:failed] = true
            notify_failure(:unhandled_reply)
            error()
          end
        else
          @selected_host[:failed] = true
          notify_failure(:guest_start_timeout)
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

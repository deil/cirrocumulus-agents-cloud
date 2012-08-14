require_relative '../../standalone/mac.rb'

module Cirrocumulus
  class Message
    def self.query_free_memory(reply_with)
      msg = Cirrocumulus::Message.new(nil, 'query-ref', [:free_memory])
      msg.ontology = 'cirrocumulus-xen'
      msg.reply_with = reply_with
      msg
    end

    def self.query_vd_state(disk_number, agent, saga_id)
      msg = Cirrocumulus::Message.new(nil, 'query-if', [:active, [:disk, [:disk_number, disk_number]]])
      msg.receiver = agent
      msg.ontology = 'cirrocumulus-xen'
      msg.conversation_id = saga_id
      msg
    end

    def self.stop_vd(disk_number)
      msg = Cirrocumulus::Message.new(nil, 'request', [:stop, [:disk, [:disk_number, disk_number]]])
      msg.ontology = 'cirrocumulus-xen'
      msg.conversation_id = 'ignored'
      msg
    end

    def self.start_vd(disk_number, agent, saga_id)
      msg = Cirrocumulus::Message.new(nil, 'request', [:start, [:disk, [:disk_number, disk_number]]])
      msg.ontology = 'cirrocumulus-xen'
      msg.receiver = agent
      msg.conversation_id = saga_id
      msg
    end
  end
end

# Starts selected VDS.
# Queries all available nodes, selects one of them and starts there VDS, meanwhile activating all necessary VDs.
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

    @vds.start()
    Log4r::Logger['agent'].info "[#{id}] Starting VDS #{vds.uid} (#{vds.id}) [RAM=#{vds.current.ram}Mb]"
    @ontology.engine.replace [:vds, vds.uid, :actual_state, :STOPPED], :starting
    handle() #if vds.uid == '048f19209e9b11de8a390800200c9a66'
  end
  
  def handle(message = nil)
    Log4r::Logger['agent'].debug(message.inspect) if message

    case @state
      when STATE_START
        msg = Cirrocumulus::Message.new(nil, 'query-if', [:running, [:guest, vds.uid]])
        msg.ontology = 'cirrocumulus-xen'
        msg.conversation_id = @id
        @ontology.agent.send_message(msg)

        change_state(STATE_SEARCHING_FOR_GUEST) # TODO: if this guest is running somewhere, we shouldn't be here..
        set_timeout(DEFAULT_TIMEOUT)
        
      when STATE_SEARCHING_FOR_GUEST
        if message.nil?
          @ontology.agent.send_message(Cirrocumulus::Message.query_free_memory(self.id))
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
          @hosts.each { |host| Log4r::Logger['agent'].info "Host #{host[:agent]} does not have enough RAM" if host[:free_memory] < vds.current.ram }
          @hosts.reject! {|host| host[:free_memory] < vds.current.ram}
          @hosts.sort! {|a,b| b[:free_memory] <=> a[:free_memory]}

          @selected_host = {:index => 0}

          if @hosts.empty?
            notify_failure(:no_suitable_nodes)
            error()
          else
            @selected_host[:attempted] = true
            @selected_host[:failed] = false

            host = @hosts[@selected_host[:index]]
            Log4r::Logger['agent'].info "[#{id}] Will try #{host[:agent]} (#{host[:free_memory]}Mb RAM available, #{vds.current.ram}Mb needed)"

            Log4r::Logger['agent'].info "[#{id}] Need to activate disks: %s" % [vds.disks.map {|d| d.storage_disk.disk_number}]
            @virtual_disk_states = vds.disks.map {|disk| {:disk => disk, :active => :do_not_know}}
            vds.disks.each do |disk|
              @ontology.agent.send_message(Cirrocumulus::Message.query_vd_state(disk.number, host[:agent], self.id))
            end

            change_state(STATE_CHECKING_VIRTUAL_DISKS)
            set_timeout(DEFAULT_TIMEOUT)
          end
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
          elsif message.content.first == :not
            disk_number = message.content[1][1][1][1].to_i # TODO: this is stupid
            @virtual_disk_states.each do |disk|
              next if disk[:disk].number != disk_number
              disk[:active] = false
              Log4r::Logger['agent'].info "[#{id}] Virtual disk #{disk[:disk].number} is not active"
            end
          end

          check_disk_states_and_do_transition()
        else # timeout
          if !check_disk_states_and_do_transition()
            error()
            notify_failure(:communication_timeout)
          end
        end

      when STATE_ACTIVATING_VIRTUAL_DISKS
        if message
          if message.act == 'inform' && message.sender == @hosts[@selected_host[:index]][:agent]
            disk_number = message.content[0][1][1][1].to_i
            @need_to_activate.each do |disk_state|
              if disk_state[:disk].number == disk_number
                disk_state[:active] = true
                @ontology.engine.assert [:virtual_disk, disk_state[:disk].number, :active_on, message.sender]
              end
            end
          end

          if all_disks_active?
            change_state(STATE_STARTING_GUEST)
            set_timeout(1)
          end
        else
          if all_disks_active?
            change_state(STATE_STARTING_GUEST)
            set_timeout(1)
          else
            notify_failure(:unable_to_activate_disks)
            error()
          end
        end

      when STATE_STARTING_GUEST
        Log4r::Logger['agent'].info "[#{id}] Starting up guest.."

        guest_parameters = [
            :guest,
            [:id, vds.uid],
            [:hvm, vds.hvm? ? 1 : 0],
            [:ram, vds.current.ram],
            [:vcpus, 4],
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
        msg.receiver = @hosts[@selected_host[:index]][:agent]
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

  def check_disk_states_and_do_transition
    return false unless all_disk_states_are_known?

    if all_disks_active?
      change_state(STATE_STARTING_GUEST)
      set_timeout(1)
    else
      @need_to_activate = @virtual_disk_states.select {|disk_state| disk_state[:active] == false}
      @need_to_activate.each do |disk_state|
        Log4r::Logger['agent'].info "[#{id}] Activating virtual disk: #{disk_state[:disk].number}"

        msg = Cirrocumulus::Message.stop_vd(disk_state[:disk].number)
        @ontology.agent.send_message(msg)

        msg = Cirrocumulus::Message.start_vd(disk_state[:disk].number, @hosts[@selected_host[:index]][:agent], self.id)
        @ontology.agent.send_message(msg)
      end

      change_state(STATE_ACTIVATING_VIRTUAL_DISKS)
      set_timeout(LONG_TIMEOUT)
    end

    true
  end

  def all_disk_states_are_known?
    @virtual_disk_states.all? {|disk_state| disk_state[:active] != :do_not_know}
  end

  def all_disks_active?
    @virtual_disk_states.all? {|disk_state| disk_state[:active] == true}
  end

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

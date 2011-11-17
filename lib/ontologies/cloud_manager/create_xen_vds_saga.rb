class CreateXenVdsSaga < Saga

  STATE_CREATE_GUEST = 1
  STATE_CREATE_DISK = 16
  STATE_NOTIFY = 32

  attr_reader :vds_config

  def start(vds_config, message)
    @vds_config = vds_config
    @message = message
    @context = @message.context if @message
    handle()
  end

  def handle(message = nil)
    case @state
      # Initial state
      when STATE_START
        Log4r::Logger['agent'].info "[#{id}] Creating new Xen VDS with RAM=#{vds_config[:ram]}Mb"
        change_state(STATE_CREATE_GUEST)
        set_timeout(1)

      when STATE_CREATE_GUEST
        @vds = VpsConfiguration.create_vds(vds_config[:ram])
        Log4r::Logger['agent'].info "[#{id}] New VDS uid is #{@vds.uid}"
        @ontology.engine.assert [:vds, @vds.uid, :state, :maintenance]
        @ontology.engine.assert [:vds, @vds.uid, :actual_state, :creating]

        if vds_config.include? :disk
          change_state(STATE_CREATE_DISK)
        else
          change_state(STATE_NOTIFY)
        end
        set_timeout(1)

      when STATE_CREATE_DISK
        Log4r::Logger['agent'].info "[#{id}] Creating required Virtual Disk with size=#{vds_config[:disk]}Gb for VDS #{@vds.uid}"
        @disk = VdsDisk.create(vds_config[:disk])
        @vds.attach_disk(@disk)
        Log4r::Logger['agent'].info "[#{id}] Virtual Disk number is #{@vds.disks.first.number}, attached as /dev/#{@vds.disks.first.block_device}"
        @ontology.engine.assert [:virtual_disk, @disk.number, :actual_state, :created]

        change_state(STATE_NOTIFY)

      when STATE_NOTIFY
        @ontology.engine.replace [:vds, @vds.uid, :actual_state, :CURRENT_STATE], :created
        Log4r::Logger['agent'].info "[#{id}] VDS #{@vds.uid} was created successfully"
        notify_finished()
        finish()
    end
  end

  protected

  def notify_finished()
    return if @message.nil?

    msg = Cirrocumulus::Message.new(nil, 'inform', [@message.content, [:finished, @vds.uid]])
    msg.ontology = @ontology.name
    msg.receiver = @context.sender
    msg.in_reply_to = @context.reply_with
    @ontology.agent.send_message(msg)
  end

end

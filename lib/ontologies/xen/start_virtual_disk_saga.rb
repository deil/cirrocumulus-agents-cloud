require_relative 'aoe.rb'
require_relative 'mdraid.rb'

class StartVirtualDiskSaga < Saga
  STATE_CHECK_EXPORTS = 1

  attr_reader :disk_number

  def start(disk_number, message = nil)
    @original_message = message
    @disk_number = disk_number

    Log4r::Logger['kb'].info "++ Starting saga #{id}: Activate VD #{self.disk_number}."
    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START
        info = @ontology.engine.match [:virtual_disk, self.disk_number, :state, :STATE]
        disk_state = :stopped
        if info.size > 0
          disk_state = info.first
        end

        if disk_state == :started
          Log4r::Logger['kb'].debug "[#{id}] VD #{self.disk_number} is already active. Quit"
          notify_refused(:already_started)
          finish()
        else
          vd = VirtualDisk.find_by_disk_number(self.disk_number)
          if vd.nil?
            Log4r::Logger['kb'].debug "[#{id}] Adding new database record for VD #{self.disk_number}"
            vd = VirtualDisk.new(self.disk_number)
            vd.save('cirrocumulus', @original_message.sender)
          end

          change_state(STATE_CHECK_EXPORTS)
          set_timeout(1)
        end

      when STATE_CHECK_EXPORTS
        aoe = Aoe.new()
        exports = aoe.exports(self.disk_number)
        md = Mdraid.assemble(self.disk_number, exports.map {|e| "e%d.%s" % [self.disk_number, e]})
        if md.clean?
          notify_finished()
          finish()
        else
          notify_failure(:unknown_error)
          error()
        end
    end
  end

  def notify_refused(reason)
    Log4r::Logger['agent'].warn "[#{id}] Refuse: #{reason}"
    return unless @original_message

    msg = Cirrocumulus::Message.new(nil, 'refuse', [@original_message.content, [reason]])
    msg.ontology = @ontology.name
    @ontology.agent.reply_to_message(msg, @original_message)
  end

  def notify_failure(reason)
    Log4r::Logger['agent'].warn "[#{id}] Failure: #{reason}"
    return unless @original_message

    msg = Cirrocumulus::Message.new(nil, 'failure', [@original_message.content, [reason]])
    msg.ontology = @ontology.name
    @ontology.agent.reply_to_message(msg, @original_message)
  end

  def notify_finished
    return unless @original_message

    msg = Cirrocumulus::Message.new(nil, 'inform', [@original_message.content, [:finished]])
    msg.ontology = @ontology.name
    @ontology.agent.reply_to_message(msg, @original_message)
  end
end

module Cirrocumulus
  class  Message
    def self.stop_md(disk_number)
      msg = self.new(nil, 'request', [:stop, [:disk, [:disk_number, disk_number]]])
      msg.ontology = 'cirrocumulus-xen'
      msg
    end

    def self.query_export(reply_with, disk_number)
      msg = Cirrocumulus::Message.new(nil, 'query-if', [:exists, [:export, [:disk_number, disk_number]]])
      msg.ontology = 'cirrocumulus-storage'
      msg.reply_with = reply_with
      msg
    end

    def self.delete_export(receiver, disk_number)
      msg = self.new(nil, 'request', [:delete, [:export, [:disk_number, disk_number]]])
      msg.receiver = receiver
      msg.ontology = 'cirrocumulus-storage'
      msg
    end

    def self.delete_volume(reply_with, disk_number)
      msg = self.new(nil, 'request', [:delete, [:volume, [:disk_number, disk_number]]])
      msg.ontology = 'cirrocumulus-storage'
      msg.reply_with = reply_with
      msg
    end
  end
end

class DeleteVirtualDiskSaga < Saga
  STATE_QUERY_EXPORTS = 1
  STATE_CHECKING_EXPORTS = 2
  STATE_SHUTDOWN_EXPORTS = 3
  STATE_DELETE_VOLUME = 4
  STATE_DELETING_VOLUME = 5

  attr_reader :disk_number

  def start(disk_number, message = nil)
    @disk_number = disk_number
    Log4r::Logger['kb'].info "++ Starting saga #{id}: Deactivate VD #{self.disk_number}"
    @ontology.engine.replace [:virtual_disk, self.disk_number, :actual_state, :CLEAN], :deactivating
    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START then
        Log4r::Logger['kb'].debug "[#{id}] Sending request to stop MD device"
        @ontology.agent.send_message(Cirrocumulus::Message.stop_md(self.disk_number))

        change_state(STATE_QUERY_EXPORTS)
        set_timeout(DEFAULT_TIMEOUT)

      when STATE_QUERY_EXPORTS
        Log4r::Logger['kb'].debug "[#{id}] Checking if VD is exported"
        @ontology.agent.send_message(Cirrocumulus::Message.query_export(self.id, self.disk_number))
        @storages_replied = 0
        change_state(STATE_CHECKING_EXPORTS)
        set_timeout(LONG_TIMEOUT)

      when STATE_CHECKING_EXPORTS
        if !message.nil?
          if message.in_reply_to == self.id && message.act == 'inform' && message.content.first == :exists
            Log4r::Logger['kb'].debug "[#{id}] Asking #{message.sender} to shutdown export for VD #{self.disk_number}"
            @ontology.agent.send_message(Cirrocumulus::Message.delete_export(message.sender, self.disk_number))
            @storages_replied += 1
          end
        end

        if message.nil? || @storages_replied == 2
          change_state(STATE_DELETE_VOLUME)
          set_timeout(0)
        end

      when STATE_DELETE_VOLUME
        Log4r::Logger['kb'].debug "[#{id}] Sending request to remove volume for VD #{self.disk_number}"
        @storages_replied = 0
        @ontology.agent.send_message(Cirrocumulus::Message.delete_volume(self.id, self.disk_number))
        change_state(STATE_DELETING_VOLUME)
        set_timeout(LONG_TIMEOUT)

      when STATE_DELETING_VOLUME
        if !message.nil?
          if message.in_reply_to == self.id && message.act == 'inform' && message.content.last.first == :finished
            Log4r::Logger['kb'].debug "[#{id}] Replied: #{message.sender}"
            @storages_replied += 1
          end
        end

        if message.nil? || @storages_replied == 2
          @ontology.engine.replace [:virtual_disk, self.disk_number, :actual_state, :DEACTIVATING], :inactive
          Log4r::Logger['kb'].debug "[#{id}] VD #{self.disk_number} was deactivated successfully"
          finish()
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

module Cirrocumulus
  class  Message
    def self.attach_block_device(reply_with, node, guest_id, disk_number, block_device)
      msg = Cirrocumulus::Message.new(nil, 'request', [:attach, [:guest_id, guest_id], [:disk_number, disk_number], [:block_device, block_device]])
      msg.receiver = node
      msg.ontology = 'cirrocumulus-xen'
      msg.reply_with = reply_with
      msg
    end
  end
end

class AttachVirtualDiskSaga < Saga
  STATE_WAITING_FOR_REPLY = 1

  attr_reader :disk_number
  attr_reader :vds_uid
  attr_reader :block_device
  attr_reader :original_message

  def start(disk_number, vds_uid, block_device, message = nil)
    @original_message = message
    @disk_number = disk_number
    @vds_uid = vds_uid
    @block_device = block_device
    
    Log4r::Logger['kb'].info "++ Starting saga #{id}: Attach VD #{self.disk_number} to VDS #{self.vds_uid} as #{self.block_device}"
    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START then
        info = @ontology.engine.match [:vds, @vds_uid, :running_on, :NODE]
        node = info.first[:NODE]
        Log4r::Logger['kb'].debug "[#{id}] VDS #{@vds_uid} is running on #{node}"

        @ontology.agent.send_message(Cirrocumulus::Message.attach_block_device(self.id, node, self.vds_uid, self.disk_number, self.block_device))

        change_state(STATE_WAITING_FOR_REPLY)
        set_timeout(DEFAULT_TIMEOUT)

      when STATE_WAITING_FOR_REPLY
        if message
          if message.act == 'inform' && message.content.last[0] == :finished
            @ontology.engine.assert [:virtual_disk, self.disk_number, :attached_to, self.vds_uid, :as, self.block_device]
            Log4r::Logger['kb'].debug "[#{id}] VD #{self.disk_number} was successfully attached to VDS #{self.vds_uid} as #{self.block_device}"

            msg = Cirrocumulus::Message.new(nil, 'inform', [self.original_message.content, [:finished]])
            msg.ontology = @ontology.name
            @ontology.agent.reply_to_message(msg, self.original_message)
            finish()
            end
        else
          msg = Cirrocumulus::Message.new(nil, 'failure', [self.original_message.content, [:unknown_reason]])
          msg.ontology = @ontology.name
          @ontology.agent.reply_to_message(msg, self.original_message)
          error()
        end
    end
  end

end

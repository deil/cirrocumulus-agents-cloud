module Cirrocumulus
  class  Message
    def self.detach_block_device(reply_with, node, guest_id, block_device)
      msg = Cirrocumulus::Message.new(nil, 'request', [:detach, [:guest_id, guest_id], [:block_device, block_device]])
      msg.receiver = node
      msg.ontology = 'cirrocumulus-xen'
      msg.reply_with = reply_with
      msg
    end
  end
end

class DetachVirtualDiskSaga < Saga
  STATE_WAITING_FOR_REPLY = 1

  attr_reader :disk_number
  attr_reader :original_message

  def start(disk_number, message = nil)
    @original_message = message
    @disk_number = disk_number
    
    vdses = @ontology.engine.match [:virtual_disk, self.disk_number, :attached_to, :VDS, :as, :BLOCK_DEVICE]
    @vds_uid = vdses.first[:VDS]
    
    Log4r::Logger['kb'].info "++ Starting saga #{id}: Detach VD #{self.disk_number} from VDS #{@vds_uid}"
    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START then
        info = @ontology.engine.match [:virtual_disk, self.disk_number, :attached_to, @vds_uid, :as, :BLOCK_DEVICE]
        block_device = info.first[:BLOCK_DEVICE]
        
        info = @ontology.engine.match [:vds, @vds_uid, :running_on, :NODE]
        node = info.first[:NODE]
        
        Log4r::Logger['kb'].debug "[#{id}] VDS #{@vds_uid} is running on #{node}, VD is attached as #{block_device}"
      
        @ontology.agent.send_message(Cirrocumulus::Message.detach_block_device(self.id, node, @vds_uid, block_device))

        change_state(STATE_WAITING_FOR_REPLY)
        set_timeout(DEFAULT_TIMEOUT)

      when STATE_WAITING_FOR_REPLY
        if message
          if message.act == 'inform' && message.content.last[0] == :finished
            info = @ontology.engine.match [:virtual_disk, self.disk_number, :attached_to, @vds_uid, :as, :BLOCK_DEVICE]
            block_device = info.first[:BLOCK_DEVICE]
            @ontology.engine.retract [:virtual_disk, self.disk_number, :attached_to, @vds_uid, :as, block_device]
            Log4r::Logger['kb'].debug "[#{id}] VD #{self.disk_number} was successfully detached from VDS #{@vds_uid}"

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

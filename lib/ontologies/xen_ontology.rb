require File.join(AGENT_ROOT, 'ontologies/xen/dom_u_kb.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/xen_db.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/xen_node.rb')
require File.join(AGENT_ROOT, 'standalone/mdraid.rb')
require File.join(AGENT_ROOT, 'standalone/dom_u.rb')
require File.join(AGENT_ROOT, 'standalone/mac.rb')

class XenOntology < Ontology::Base
  def initialize(agent)
    super('cirrocumulus-xen', agent)
  end

  def restore_state()
    XenNode.set_cpu(0, 10000, 0)
    changes_made = 0
    Mdraid.list_disks().each do |discovered|
      disk = VirtualDisk.find_by_disk_number(discovered)
      next if disk

      logger.info "autodiscovered virtual disk %d" % [discovered]
      disk = VirtualDisk.new(discovered)
      disk.save('discovered')
    end

    known_disks = VirtualDisk.all
    known_disks.each do |disk|
      if Mdraid.get_status(disk.disk_number) == :stopped
        logger.info "bringing up disk %d" % [disk.disk_number]
        changes_made += 1 if Mdraid.assemble(disk.disk_number)
      end
    end

    logger.info "restored state, made %d changes" % [changes_made]
  end

  def handle_message(message, kb)
    case message.act
      when 'query-ref' then
        msg = query(message.content)
        msg.receiver = message.sender
        msg.ontology = self.name
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)

      when 'query-if'
        msg = query_if(message.content)
        msg.receiver = message.sender
        msg.ontology = self.name
        msg.in_reply_to = message.reply_with
        self.agent.send_message(msg)

      when 'request' then
        handle_request(message)
    end
  end

  private

  def query(obj)
    msg = Cirrocumulus::Message.new(nil, 'inform', nil)

    if obj.first == :free_memory
      msg.content = [:'=', obj, [XenNode.free_memory]]
    elsif obj.first == :used_memory
      msg.content = [:'=', obj, [XenNode.total_memory - XenNode.free_memory]]
    elsif obj.first == :guests_count
      msg.content = [:'=', obj, [XenNode.list_running_guests().size]]
    end

    msg
  end

  def query_if(obj)
    msg = Cirrocumulus::Message.new(nil, 'inform', nil)

    if obj.first == :running
      msg.content = handle_running_query(obj) ? obj : [:not, obj]
    end

    msg
  end

  # (running (guest ..))
  def handle_running_query(obj)
    obj.each do |param|
      next if !param.is_a?(Array)
      if param.first.is_a?(Symbol) && param.first == :guest
        guest_id = param.second
        return XenNode::is_guest_running?(guest_id)
      end
    end

    false
  end

end

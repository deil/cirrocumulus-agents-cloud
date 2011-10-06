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
      if Mdraid.check_status(disk.disk_number) == :stopped
        logger.info "bringing up disk %d" % [disk.disk_number]
        changes_made += 1 if Mdraid.assemble(disk.disk_number)
      end
    end

  end

  def handle_message(message, kb)
  end

  private

end

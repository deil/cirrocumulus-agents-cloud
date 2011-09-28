require 'systemu'
require File.join(AGENT_ROOT, 'ontologies/xen/xen_db.rb')
require File.join(AGENT_ROOT, 'ontologies/xen/mdraid.rb')

class XenOntology < Ontology::Base
  def initialize(agent)
    super('cirrocumulus-xen', agent)
  end

  def restore_state()
    changes_made = 0
    p Mdraid.list_disks()
  end

  def handle_message(message, kb)
  end

  private

end

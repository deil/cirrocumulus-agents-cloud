require 'rubygems'
require 'systemu'
require File.join(AGENT_ROOT, 'ontologies/xen/xen_db.rb')

class XenOntology < Ontology::Base
  def initialize(agent)
    super('cirrocumulus-xen', agent)
  end

  def restore_state()
  end

  def handle_message(message, kb)
  end

  private

end

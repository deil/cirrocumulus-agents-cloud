require_relative '../config/xen_config'
require_relative 'hypervisor/hypervisor'
require_relative 'hypervisor/hypervisor_db'
require_relative 'hypervisor/mac'
require_relative 'hypervisor/mdraid'

class HypervisorOntology < Ontology
  ontology 'hypervisor'

  rule 'init', [[:just_started]] do |ontology, params|
    Hypervisor.connect
    Hypervisor.set_cpu(0, 10000, 0)
    ontology.retract [:just_started]
  end

  def restore_state
    assert [:just_started]
  end

  def handle_query(sender, expression, options = {})
    if expression == [:free_memory]
      inform(sender, [[:free_memory], 1024], reply(options))
    else
      super(sender, expression, options)
    end
  end

  def handle_request(sender, contents, options = {})

  end
end

require 'cirrocumulus/rule_engine'

class CloudRuleset < RuleEngine::Base
  attr_reader :ontology
  def initialize(ontology)
    @ontology = ontology
  end

  rule 'running_vds_suddenly_terminated', [[:vds, :VDS, :should_be_running], [:guest, :VDS, :powered_off]] do |engine, params|
    vds = params[:VDS]
    
    if !engine.query [:vds, vds, :starting]
      Log4r::Logger['kb'].warn "VDS #{vds} has been unexpectedly terminated"
      engine.assert [:vds, vds, :starting]

      matched_nodes = engine.match [:vds, vds, :running_on, :NODE]
      matched_nodes.each do |node_info|
        engine.retract [:vds, vds, :running_on, node_info[:NODE]]
      end

      #engine.dump_kb()
      #sleep 10
      engine.ontology.start_vds(VpsConfiguration.find_by_uid(vds))
    end
  end
end

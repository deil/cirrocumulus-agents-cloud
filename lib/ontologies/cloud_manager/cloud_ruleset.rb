require 'cirrocumulus/rule_engine'

class CloudRuleset < RuleEngine::Base
  attr_reader :ontology
  def initialize(ontology)
    @ontology = ontology
  end

  rule 'running_vds_suddenly_terminated', [[:vds, :VDS, :running_on, :NODE], [:guest, :VDS, :powered_off]] do |engine, params|
    vds = params[:VDS]
    node = params[:NODE]
    
    if !engine.query [:vds, vds, :starting]
      Log4r::Logger['kb'].warn "VDS #{vds} has been unexpectedly terminated on #{node}"
      #engine.dump_kb()
      #sleep 10
      engine.retract [:vds, vds, :running_on, node]
      engine.ontology.start_vds(VpsConfiguration.find_by_uid(vds))
    end
  end
end

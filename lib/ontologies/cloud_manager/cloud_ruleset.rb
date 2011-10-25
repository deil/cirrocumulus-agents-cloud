require 'cirrocumulus/rule_engine'

class CloudRuleset < RuleEngine::Base
  attr_reader :ontology
  def initialize(ontology)
    @ontology = ontology
  end

  rule 'running_vds_suddenly_terminated', [[:vds, :VDS, :running_on, :NODE], [:guest, :VDS, :powered_off]] do |engine, params|
    vds = params[:VDS]
    node = params[:NODE]
    
    if !engine.query [:guest, vds, :starting]
      Log4r::Logger['kb'].warn "VDS #{vds} has been unexpectedly terminated on #{node}"
    end
  end
end

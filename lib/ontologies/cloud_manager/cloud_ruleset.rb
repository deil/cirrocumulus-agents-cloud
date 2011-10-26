require 'cirrocumulus/rule_engine'

class CloudRuleset < RuleEngine::Base
  attr_reader :ontology
  def initialize(ontology)
    @ontology = ontology
  end
  
  rule 'vds_should_be_stopped', [[:vds, :VDS, :running_on, :NODE], [:vds, :VDS, :should_be_stopped]] do |engine, params|
    vds = params[:VDS]
    
    if !engine.query([:vds, vds, :stopping])
      node = params[:NODE]
      Log4r::Logger['kb'].info "Stopping VDS #{vds} (running on #{node})"
      engine.assert [:vds, vds, :stopping]
      engine.retract [:vds, vds, :should_be_running] if engine.query [:vds, vds, :should_be_running]
      engine.ontology.stop_vds(VpsConfiguration.find_by_uid(vds))
    end
  end
  
  rule 'vds_should_be_stopped_but_started_externally', [[:guest, :VDS, :powered_on], [:vds, :VDS, :should_be_stopped]] do |engine, params|
    vds = params[:VDS]
    if engine.match([:vds, vds, :running_on, :NODE]).empty?
      Log4r::Logger['kb'].warn "Externally started VDS #{vds}"
    end
  end
  
  rule 'vds_should_be_running', [[:vds, :VDS, :should_be_running]] do |engine, params|
    vds = params[:VDS]
    
    if !engine.query([:vds, vds, :starting]) && !engine.query([:guest, vds, :powered_off])
      matched_nodes = engine.match [:vds, vds, :running_on, :NODE]
      if matched_nodes.empty?
        Log4r::Logger['kb'].info "Starting VDS #{vds}"
        engine.assert [:vds, vds, :starting]
        engine.retract [:vds, vds, :should_be_stopped] if engine.query [:vds, vds, :should_be_stopped]
        engine.ontology.start_vds(VpsConfiguration.find_by_uid(vds))
      end
    end
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

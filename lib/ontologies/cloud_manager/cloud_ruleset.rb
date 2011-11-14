require 'cirrocumulus/rule_engine'

class CloudRuleset < RuleEngine::Base
  attr_reader :ontology

  def initialize(ontology)
    @ontology = ontology
  end

  #
  # VDS has unknown actual state, we need to query all nodes and understand if it is running somewhere
  #
  rule 'unknown_vds_state', [ [:vds, :VDS, :actual_state, :unknown] ] do |engine, params|
    vds_uid = params[:VDS]

    Log4r::Logger['kb'].info "Need to query VDS #{vds_uid} state"
    vds = VpsConfiguration.find_by_uid(vds_uid)
    if vds.vds_type == "xen"
      engine.ontology.query_xen_vds_state(vds)
    else
      Log4r::Logger['kb'].warn "VDS #{vds_uid} type is not supported"
    end
  end

  #
  # We known that VDS must be running, but it's actual state is OFF. So, attempt to turn it on
  #
  rule 'vds_should_be_running', [ [:vds, :VDS, :state, :running], [:vds, :VDS, :actual_state, :stopped] ] do |engine, params|
    vds = params[:VDS]

    matched_nodes = engine.match [:vds, vds, :running_on, :NODE]
    matched_nodes.each {|match| engine.retract [:vds, vds, :running_on, match[:NODE]]}

    Log4r::Logger['kb'].info "Xen VDS #{vds} is powered off, but should be running"
    engine.ontology.start_xen_vds(VpsConfiguration.find_by_uid(vds))
  end

  #
  # VDS must be running, but we received fact that corresponding domU has been suddenly (externally) turned off.
  # We need to retract information about current node where our VDS was running and update it's actual state
  #
  rule 'running_vds_terminated_externally', [ [:vds, :VDS, :state, :running], [:vds, :VDS, :actual_state, :running],
                                                                      [:guest, :VDS, :powered_off] ] do |engine, params|
    vds = params[:VDS]

    matched_nodes = engine.match [:vds, vds, :running_on, :NODE]
    if matched_nodes.size > 1
      Log4r::Logger['kb'].warn "WTF!? Xen VDS #{vds} is running on multiple nodes"
    end

    matched_nodes.each do |match|
      Log4r::Logger['kb'].warn "Xen VDS #{vds} terminated on #{match[:NODE]}"
      engine.retract [:vds, vds, :running_on, match[:NODE]], true
    end

    engine.retract [:guest, vds, :powered_off], true
    engine.replace [:vds, vds, :actual_state, :RUNNING_STATE], :stopped
  end

  #
  # Currently running VDS must be stopped from now. Turn it off
  #
  rule 'vds_should_be_stopped', [ [:vds, :VDS, :actual_state, :running], [:vds, :VDS, :state, :stopped] ] do |engine, params|
    vds = params[:VDS]

    Log4r::Logger['kb'].info "Xen VDS #{vds} is powered on, but should be stopped"

    matched_nodes = engine.match [:vds, vds, :running_on, :NODE]
    if matched_nodes.size > 1
      Log4r::Logger['kb'].warn "WTF!? Xen VDS #{vds} is running on multiple nodes"
    end

    matched_nodes.each do |match|
      Log4r::Logger['kb'].info "Xen VDS #{vds} is currently running on #{match[:NODE]}"
    end

    engine.ontology.stop_xen_vds(VpsConfiguration.find_by_uid(vds))
  end
  
  rule 'vds_should_be_stopped_but_started_externally', [[:guest, :VDS, :powered_on], [:vds, :VDS, :should_be_stopped]] do |engine, params|
    vds = params[:VDS]
    if engine.match([:vds, vds, :running_on, :NODE]).empty?
      Log4r::Logger['kb'].warn "Externally started VDS #{vds}"
    end
  end

  #
  # Need to build new VDS
  #
  rule 'build_new_vds', [ [:vds, :VDS, :state, :maintenance], [:vds, :VDS, :actual_state, :building] ] do |engine, params|
    vds_uid = params[:VDS]

    vds = VpsConfiguration.find_by_uid(vds_uid)
    all_disks_clean = true
    vds.disks.each do |disk|
      all_disks_clean &&= engine.query [:virtual_disk, disk.number, :actual_state, :clean]
    end

    if all_disks_clean
      Log4r::Logger['kb'].info "Building VDS #{vds_uid}"
      engine.replace [:vds, vds_uid, :actual_state, :CURRENT_STATE], :stopped
    end
  end

  #
  # Need to build Virtual Disk
  #
  rule 'build_virtual_disk', [ [:virtual_disk, :NUMBER, :actual_state, :created] ] do |engine, params|
    disk_number = params[:NUMBER]
    Log4r::Logger['kb'].info "Building Virtual Disk #{disk_number}"
    disk = VdsDisk.find_by_number(disk_number)
    engine.ontology.build_disk(disk)
  end
end

require 'cirrocumulus/rule_engine'

class CloudRuleset < RuleEngine::Base
  attr_reader :ontology

  def initialize(ontology)
    super()

    info("Created new CloudRuleset instance.")
    @ontology = ontology
  end

  def info(msg)
    Log4r::Logger['kb'].info(msg)
  end

  def error(msg)
    Log4r::Logger['kb'].warn(msg)
  end

  #
  # Called on initialization. Connect to backend DB, grab all active VDSes and query their states
  #
  rule 'init', [ [:just_started] ] do |engine, params|
    engine.info("Collecting information about all active virtual servers..")
    engine.retract [:just_started]

    VdsDisk.all.each do |disk|
      engine.assert [:virtual_disk, disk.number, :state, :active]
      engine.assert [:virtual_disk, disk.number, :actual_state, :clean]
    end

    VpsConfiguration.active.each do |vds|
      if vds.is_running?
        engine.assert [:vds, vds.uid, :state, :running]
      else
        engine.assert [:vds, vds.uid, :state, :stopped]
      end

      engine.assert [:vds, vds.uid, :actual_state, :unknown]

      vds.disks.each do |disk|
        engine.assert [:virtual_disk, disk.number, :attached_to, vds.uid, :as, disk.block_device]
      end
    end
  end

  #
  # VDS has unknown actual state, we need to query all nodes and understand if it is running somewhere
  #
  rule 'unknown_vds_state', [ [:vds, :VDS, :actual_state, :unknown] ] do |engine, params|
    vds_uid = params[:VDS]

    engine.info("Must query VDS #{vds_uid} state (current: unknown)")

    vds = VpsConfiguration.find_by_uid(vds_uid)
    if vds
      engine.ontology.query_xen_vds_state(vds.uid)
    else
      engine.error("!! VDS #{vds_uid} does not exist")
    end
  end

  #
  # We known that VDS must be running, but it's actual state is OFF. So, attempt to turn it on
  #
  rule 'vds_should_be_running', [ [:vds, :VDS, :state, :running], [:vds, :VDS, :actual_state, :stopped] ] do |engine, params|
    vds = params[:VDS]

    matched_nodes = engine.match [:vds, vds, :running_on, :NODE]
    matched_nodes.each {|match| engine.retract [:vds, vds, :running_on, match[:NODE]]}

    Log4r::Logger['cirrocumulus'].info "VDS #{vds} state is: stopped, should be: running"
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
      Log4r::Logger['cirrocumulus'].warn "WTF!? Xen VDS #{vds} is running on multiple nodes"
    end

    matched_nodes.each do |match|
      Log4r::Logger['cirrocumulus'].warn "Xen VDS #{vds} terminated on #{match[:NODE]}"
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

    Log4r::Logger['cirrocumulus'].info "Xen VDS #{vds} is powered on, but should be stopped"

    matched_nodes = engine.match [:vds, vds, :running_on, :NODE]
    if matched_nodes.size > 1
      Log4r::Logger['cirrocumulus'].warn "WTF!? Xen VDS #{vds} is running on multiple nodes"
    end

    matched_nodes.each do |match|
      Log4r::Logger['cirrocumulus'].info "Xen VDS #{vds} is currently running on #{match[:NODE]}"
    end

    engine.ontology.stop_xen_vds(VpsConfiguration.find_by_uid(vds))
  end

  #
  # VDS should be stopped, but somebody informed that it is running. Heh
  #
  rule 'vds_should_be_stopped_but_started_externally', [[:guest, :VDS, :powered_on], [:vds, :VDS, :should_be_stopped]] do |engine, params|
    vds = params[:VDS]
    if engine.match([:vds, vds, :running_on, :NODE]).empty?
      Log4r::Logger['cirrocumulus'].warn "Externally started VDS #{vds}"
    end
  end

  #
  # Need to build new VDS. Firstly, we wait until all attached disks are ready.
  #
  rule 'build_vds', [ [:vds, :VDS, :state, :maintenance], [:vds, :VDS, :actual_state, :created] ] do |engine, params|
    vds_uid = params[:VDS]

    vds = VpsConfiguration.find_by_uid(vds_uid)
    all_disks_clean = true
    vds.disks.each do |disk|
      all_disks_clean &&= engine.query [:virtual_disk, disk.number, :actual_state, :clean]
    end

    if all_disks_clean
      Log4r::Logger['cirrocumulus'].info "Building VDS #{vds_uid}"
      engine.ontology.build_xen_vds(vds)
    end
  end

  #
  # Need to build Virtual Disk
  #
  rule 'build_virtual_disk', [ [:virtual_disk, :NUMBER, :actual_state, :created] ] do |engine, params|
    disk_number = params[:NUMBER]
    Log4r::Logger['cirrocumulus'].info "Building Virtual Disk #{disk_number}"
    disk = VdsDisk.find_by_number(disk_number)
    engine.ontology.build_disk(disk)
  end
  
  #
  # Deactivate virtual disk (shutdown all MD devices, remove exports and delete volumes on both storages)
  #
  rule 'deactivate_virtual_disk', [ [:virtual_disk, :NUMBER, :state, :inactive], [:virtual_disk, :NUMBER, :actual_state, :clean] ] do |engine, params|
    disk_number = params[:NUMBER]
    disk = VdsDisk.find_by_number(disk_number)
    if disk
      engine.info "Deactivating Virtual Disk #{disk_number}"
      engine.ontology.start_delete_virtual_disk_saga(disk_number)
    else
    end
  end
  
  #
  # Delete information about inactive virtual disk from backend DB
  #
  rule 'delete_virtual_disk', [ [:virtual_disk, :NUMBER, :state, :inactive], [:virtual_disk, :NUMBER, :actual_state, :inactive] ] do |engine, params|
    disk_number = params[:NUMBER]
    engine.info "Deleting information about Virtual Disk #{disk_number}"
    disk = VdsDisk.find_by_number(disk_number)
    disk.delete()

    engine.retract [:virtual_disk, disk_number, :state, :inactive]
    engine.retract [:virtual_disk, disk_number, :actual_state, :inactive]
  end
end

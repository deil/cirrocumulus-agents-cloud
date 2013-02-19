require_relative 'cloud_manager/cloud_db-o1'
require_relative 'cloud_manager/query_xen_vds_state_saga'
require_relative 'cloud_manager/reboot_xen_vds_saga'

class CloudOntology < Ontology
  ontology 'cloud'

  #
  # Called on initialization. Connect to backend DB, grab all active VDSes and query their states
  #
  rule 'init', [ [:just_started] ] do |ontology, params|
    ontology.retract [:just_started]

    ontology.discover_nodes()
    ontology.discover_storages()

    VdsDisk.all.each do |disk|
      ontology.assert [:virtual_disk, disk.number, :state, :active]
      ontology.assert [:virtual_disk, disk.number, :actual_state, :clean]
    end

    VpsConfiguration.active.each do |vds|
      if vds.is_running?
        ontology.assert [:vds, vds.uid, :state, :running]
      else
        ontology.assert [:vds, vds.uid, :state, :stopped]
        Log4r::Logger['ontology::cloud'].info "Active VDS #{vds.uid} is stopped."
      end

      ontology.assert [:vds, vds.uid, :actual_state, :unknown]

      vds.disks.each do |disk|
        ontology.assert [:virtual_disk, disk.number, :attached_to, vds.uid, :as, disk.block_device]
      end
    end

    ontology.assert [:initialized]
  end

  #
  # VDS has unknown actual state, we need to query all nodes and understand if it is running somewhere
  #
  rule 'unknown_vds_state', [ [:vds, :VDS, :actual_state, :unknown], [:initialized] ] do |ontology, params|
    vds_uid = params[:VDS]

    Log4r::Logger['ontology::cloud'].info("Must query VDS #{vds_uid} state (current: unknown)")

    vds = VpsConfiguration.find_by_uid(vds_uid)
    if vds
      ontology.query_xen_vds_state(vds.uid)
    else
      Log4r::Logger['ontology::cloud'].error("!! VDS #{vds_uid} does not exist")
    end
  end

  def discover_nodes
    #create_saga(QueryNodesSaga).start()
  end

  def discover_storages
    #create_saga(QueryStoragesSaga).start()
  end

  def query_xen_vds_state(vds_uid)
    saga = create_saga(QueryXenVdsStateSaga)
    saga.start(vds_uid, nil)
  end

  def start_xen_vds(vds)
    saga = create_saga(StartVdsSaga)
    saga.start(vds, nil) #if vds.uid == "048f19209e9b11de8a390800200c9a66"
  end

  def stop_xen_vds(vds)
    create_saga(StopVdsSaga).start(vds, nil)
  end

  def restore_state
    assert [:just_started]
  end

  def handle_request(sender, contents, options = {})
    action = contents[0]
    if action == :reboot
      object = contents[1]
      if object.first == :vds
        agree(sender, contents, reply(options))
      end
    end
  end

end

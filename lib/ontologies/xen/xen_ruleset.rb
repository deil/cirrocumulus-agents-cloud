require 'cirrocumulus/rule_engine'

class XenEngine < RuleEngine::Base
  attr_reader :agent
  
  def initialize(agent)
    @agent = agent
  end
  
  rule 'initialize', [[:just_started]] do |engine, params|
    engine.retract [:just_started]
  end
  
  rule 'guest_powered_off', [[:guest, :X, :powered_off]] do |engine, params|
    guest = params[:X]
    Log4r::Logger['kb'].warn "Guest #{guest} has been powered off"
    msg = Cirrocumulus::Message.new(nil, 'inform', [:guest, guest, :powered_off])
    msg.ontology = 'cirrocumulus-cloud'
    engine.agent.send_message(msg) if engine.agent
  end
  
  rule 'repair_mdraid', [[:virtual_disk, :X, :active], [:mdraid, :X, :failed]] do |engine, params|
    if !engine.query([:mdraid, params[:X], :repairing]) && !engine.query([:mdraid, params[:X], :unable_to_repair])
      x = params[:X]
      engine.assert [:mdraid, x, :repairing]
      Log4r::Logger['kb'].info "MD device for virtual disk #{x} has failed, attempting to repair"

      raid = Mdraid.new(x)
      Log4r::Logger['kb'].info "md#{x}: checking AoE devices count"
      devices = raid.aoe_devices
      Log4r::Logger['kb'].info "md#{x}: found %d device(s) - %s" % [devices.size, devices.inspect]
      devices_state = devices.map {|dev| raid.component_up? dev}
      if devices.size == 1 && devices_state.first == false
        Log4r::Logger['kb'].info "md#{x} solution: all RAID components are failed, device is UNOPERATABLE"
        engine.assert [:mdraid, x, :unable_to_repair]
      elsif devices.size == 1 # only one device, need to re-add second one
        Log4r::Logger['kb'].info "md#{x} solution: need to re-add second device"
      elsif devices.size == 2 && (devices_state.first == false || devices_state.second == false)
        failed_device = devices_state.first == false ? devices.first : devices.second
        Log4r::Logger['kb'].info "md#{x} solution: repair AoE export #{failed_device}"
      else # WTF!?
        Log4r::Logger['kb'].info "md#{x}: device states are %s" % devices_state.inspect
        Log4r::Logger['kb'].info "md#{x} solution: NO SOLUTION"
        engine.assert [:mdraid, x, :unable_to_repair]
      end

      #engine.retract [:mdraid, x, :repairing]
    end
  end
end

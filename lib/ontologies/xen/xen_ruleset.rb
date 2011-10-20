require 'cirrocumulus/rule_engine'

class XenEngine < RuleEngine::Base
  rule 'initialize', [[:just_started]] do |engine, params|
    XenNode.set_cpu(0, 10000, 0)
    engine.retract [:just_started]
  end
  
  rule 'repair_mdraid', [[:virtual_disk, :X, :active], [:mdraid, :X, :failed]] do |engine, params|
    return if engine.query [:mdraid, params[:X], :repairing]
    x = params[:X]
    engine.assert [:mdraid, x, :repairing]
    Log4r::Logger['kb'].info "MD device for virtual disk #{x} has failed, attempting to repair"

    raid = Mdraid.new(x)
    Log4r::Logger['kb'].debug "md#{x}: checking AoE devices count"
    Log4r::Logger['kb'].debug "md#{x}: found %d device(s) - %s" % [raid.aoe_devices.size, raid.aoe_devices.inspect]

    engine.retract [:mdraid, x, :repairing]
  end
end

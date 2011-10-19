require 'cirrocumulus/rule_engine'

class XenEngine < RuleEngine::Base
  rule 'initialize', [[:just_started]] do |engine, params|
    XenNode.set_cpu(0, 10000, 0)
    engine.retract [:just_started]
  end
  
  rule 'repair_mdraid', [[:virtual_disk, :X, :active], [:mdraid, :X, :failed]] do |engine, params|
    x = params[:X]
    log "MD device for virtual disk #{x} has failed, attempting to repair"
    engine.retract [:mdraid, x, :failed]
  end
end

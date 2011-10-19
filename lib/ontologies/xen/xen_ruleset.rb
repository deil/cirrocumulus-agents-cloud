require 'cirrocumulus/rule_engine'

class XenEngine < RuleEngine::Base
  rule 'initialize', [[:just_started]] do |engine, params|
    XenNode.set_cpu(0, 10000, 0)
    engine.retract [:just_started]
  end
end
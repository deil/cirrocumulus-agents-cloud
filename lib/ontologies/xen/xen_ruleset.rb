require 'cirrocumulus/rule_engine'

class XenEngine < RuleEngine::Base
  attr_reader :ontology
  
  def initialize(ontology)
    @ontology = ontology
  end
  
  rule 'initialize', [[:just_started]] do |engine, params|
    XenNode.connect()
    XenNode.set_cpu(0, 10000, 0)
    msg = Cirrocumulus::Message.new(nil, 'inform', [:node, "%s-%s" % [system('hostname'), engine.ontology.name], XenNode.free_memory])
    msg.ontology = 'cirrocumulus-cloud'
    engine.ontology.agent.send_message(msg)
    engine.retract [:just_started]
  end
  
  rule 'guest_powered_off', [[:guest, :X, :just_powered_off]] do |engine, params|
    guest = params[:X]
    Log4r::Logger['kb'].warn "Guest #{guest} has been powered off"
    msg = Cirrocumulus::Message.new(nil, 'inform', [:guest, guest, :powered_off])
    msg.ontology = 'cirrocumulus-cloud'
    engine.ontology.agent.send_message(msg) if engine.agent
    engine.retract [:guest, guest, :just_powered_off]
    engine.retract [:guest, guest, :powered_on] if engine.query [:guest, guest, :powered_on]
    engine.assert [:guest, guest, :powered_off]
  end
  
  rule 'guest_powered_on', [[:guest, :X, :just_powered_on]] do |engine, params|
    guest = params[:X]
    Log4r::Logger['kb'].info "Unrecognized guest #{guest} has been powered on"
    msg = Cirrocumulus::Message.new(nil, 'inform', [:guest, guest, :powered_on])
    msg.ontology = 'cirrocumulus-cloud'
    engine.ontology.agent.send_message(msg) if engine.agent
    engine.retract [:guest, guest, :just_powered_on]
    engine.retract [:guest, guest, :powered_off] if engine.query [:guest, guest, :powered_off]
    engine.assert [:guest, guest, :powered_on]
  end
end

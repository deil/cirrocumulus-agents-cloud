require 'cirrocumulus/rule_engine'

class XenRuleset < RuleEngine::Base
  attr_reader :ontology
  
  def initialize(ontology)
    super()
    info("Created new XenRuleset instance.")
    @ontology = ontology
  end

  def info(msg)
    Log4r::Logger['kb'].info(msg)
  end

  def error(msg)
    Log4r::Logger['kb'].warn(msg)
  end
  
  rule 'initialize', [[:just_started]] do |engine, params|
    XenNode.connect()
    XenNode.set_cpu(0, 10000, 0)
    msg = Cirrocumulus::Message.new(nil, 'inform', [:node, "%s-%s" % [`hostname`.strip, engine.ontology.name.gsub('cirrocumulus-', '')], XenNode.free_memory])
    msg.ontology = 'cirrocumulus-cloud'
    engine.ontology.agent.send_message(msg)
    engine.retract [:just_started]
  end

  rule 'aoe_appeared', [ [:aoe, :DISK_NUMBER, :EXPORT, :up] ] do |engine, params|
    Log4r::Logger['kb'].info "New AOE export: #{params[:DISK_NUMBER]}.#{params[:EXPORT]}"
  end

  rule 'aoe_dissapeared', [ [:aoe, :DISK_NUMBER, :EXPORT, :down] ] do |engine, params|
    Log4r::Logger['kb'].info "AOE export is down: #{params[:DISK_NUMBER]}.#{params[:EXPORT]}"
  end
  
  rule 'guest_powered_off', [[:guest, :X, :just_powered_off]] do |engine, params|
    guest = params[:X]
    Log4r::Logger['kb'].warn "Guest #{guest} has been powered off"
    msg = Cirrocumulus::Message.new(nil, 'inform', [:guest, guest, :powered_off])
    msg.ontology = 'cirrocumulus-cloud'
    engine.ontology.agent.send_message(msg) if engine.ontology
    engine.retract [:guest, guest, :just_powered_off]
    engine.retract [:guest, guest, :running] if engine.query [:guest, guest, :running]
    engine.assert [:guest, guest, :powered_off]
  end
  
  rule 'guest_powered_on', [[:guest, :X, :just_powered_on]] do |engine, params|
    guest = params[:X]
    Log4r::Logger['kb'].info "Unrecognized guest #{guest} has been powered on"
    msg = Cirrocumulus::Message.new(nil, 'inform', [:guest, guest, :running])
    msg.ontology = 'cirrocumulus-cloud'
    engine.ontology.agent.send_message(msg) if engine.ontology
    engine.retract [:guest, guest, :just_powered_on]
    engine.retract [:guest, guest, :powered_off] if engine.query [:guest, guest, :powered_off]
    engine.assert [:guest, guest, :running]
  end

end

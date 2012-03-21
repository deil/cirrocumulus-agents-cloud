require 'cirrocumulus/rule_engine'

class StorageRuleset < RuleEngine::Base
  attr_reader :ontology

  def initialize(ontology)
    super()
    @ontology = ontology
  end

end

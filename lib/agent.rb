require 'bundler/setup'
require 'cirrocumulus'
require 'cirrocumulus/remote_console'
require_relative 'ontologies/hypervisor_ontology'

Ontology.enable_console

agent = Cirrocumulus::Environment.new(`hostname`.chomp)
agent.load_ontology(HypervisorOntology.new(Agent.network('hypervisor')))
agent.run
agent.join

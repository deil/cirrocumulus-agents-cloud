require 'bundler/setup'
require 'log4r/configurator'
require 'cirrocumulus'
require 'cirrocumulus/remote_console'

require_relative 'ontologies/hypervisor_ontology'
#require_relative 'ontologies/cloud_ontology'

Encoding.default_internal = Encoding.default_external = 'UTF-8'

Log4r::Configurator.load_xml_file('config/log4r.xml')

JabberChannel::server '172.16.11.4'
JabberChannel::password 'q1w2e3r4'
JabberChannel::conference 'cirrocumulus'

Ontology.enable_console

agent = Cirrocumulus::Environment.new(`hostname`.chomp)
#agent.load_ontology(CloudOntology.new(Agent.network('cloud2')))
agent.load_ontology(HypervisorOntology.new(Agent.network('hypervisor')))
agent.run
gets
agent.join

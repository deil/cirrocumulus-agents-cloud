AGENT_ROOT = File.dirname(__FILE__)

require 'config/jabber_config.rb'
require 'rubygems'
require 'bundler/setup'
require 'yaml'
require 'cirrocumulus'
require 'cirrocumulus/logger'
require 'cirrocumulus/engine'
require 'cirrocumulus/kb'
require 'cirrocumulus/ontology'
require 'cirrocumulus/master_agent'

class String
  def underscore
    self.gsub(/::/, '/').
    gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
    gsub(/([a-z\d])([A-Z])/,'\1_\2').
    tr("-", "_").
    downcase
  end
end

ontologies_file_name = nil

ARGV.each_with_index do |arg, i|
  if arg == '-c'
    ontologies_file_name = ARGV[i + 1]
  end
end

if ontologies_file_name.nil?
  puts "Please supply config file name"
  return
end

puts "Loading configuration.."
agent_config = YAML.load_file(ontologies_file_name)
ontologies = agent_config['ontologies']
ontologies.each do |ontology_name|
  puts "Will load ontology %s" % ontology_name
  require File.join(AGENT_ROOT, 'ontologies', ontology_name.underscore)
end

kb_name = agent_config['kb']
kb = if kb_name
  puts "Will load knowledge base %s" % kb_name
  require File.join(AGENT_ROOT, 'ontologies/xen/', kb_name.underscore) # TODO
  eval("#{kb_name}.new()")
else
  Kb.new
end

cm = Cirrocumulus.new('master')
a = Agent::Base.new(cm)
a.load_ontologies(agent_config['ontologies'])
begin
  cm.run(a, kb)
rescue Exception => e
  puts 'Got an error:'
  puts e
  puts e.backtrace
end

puts "\nBye-bye."

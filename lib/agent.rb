AGENT_ROOT = File.dirname(__FILE__)
require File.join(AGENT_ROOT, 'config/jabber_config.rb')
require 'rubygems'
require 'bundler/setup'
require 'cirrocumulus/agent_wrapper'

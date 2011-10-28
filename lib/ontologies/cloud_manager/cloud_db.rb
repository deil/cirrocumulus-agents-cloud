require 'active_support'
require 'active_record'

class KnownFact < ActiveRecord::Base
  named_scope :current, :conditions => {:is_active => 1}
end

class VpsConfiguration
  attr_accessor :id
  attr_accessor :vds_type
  attr_accessor :uid
  attr_accessor :hvm
  attr_accessor :current
  attr_accessor :disks

  def initialize(id, vds_type, uid, ram)
    @id = id
    @vds_type = vds_type
    @uid = uid
    @current = VdsConfigurationHistory.new(ram)
  end

  def hvm?
    hvm == 1
  end

  def self.all
    vdses = []
    KnownFact.all(:conditions => ['key like "vds_%%"']).each do |f|
      if f.key =~ /vds_(\w+)$/
        vds_uid = $1
        vdses << self.find_by_uid(vds_uid)
      end
    end

    vdses
  end

  def self.running
    vdses = []
    KnownFact.all(:conditions => ['key like "vds_%%"']).each do |f|
      if f.key =~ /vds_(\w+)$/
        vds_uid = $1
        vdses << self.find_by_uid(vds_uid)
      end
    end

    vdses
  end

  def self.find_by_uid(vds_uid)
    fact = KnownFact.current.find_by_key('vds_' + vds_uid)
    return nil unless fact

    json = ActiveSupport::JSON.decode(fact.value)
    vds = VpsConfiguration.new(json['id'], json['vds_type'], json['uid'], json['current']['ram'])
    vds.hvm = json['hvm']
    vds.disks = json['disks'].map {|disk| VdsDisk.new(vds, disk['disk_number'], disk['priority'])} if json['disks']
    vds
  end

  def save(origin = nil, agent = nil)
    fact = KnownFact.current.find_by_key('vds_' + uid)
    fact = KnownFact.new(:key => 'vds_' + uid, :is_active => 1) unless fact
    disks.each {|disk| disk.vds = nil}
    fact.value = self.to_json
    disks.each {|disk| disk.vds = self}
    fact.origin = origin
    fact.agent = agent
    fact.save
  end

  def delete
    fact = KnownFact.current.find_by_key('vds_' + uid)
    fact.update_attributes(:is_active => false) if fact
  end
end

class VdsConfigurationHistory
  attr_accessor :ram

  def initialize(ram)
    self.ram = ram
  end
end

class VdsDisk
  attr_accessor :disk_number
  attr_accessor :priority
  attr_accessor :vds

  def initialize(vds, disk_number, priority)
    @vds = vds
    self.disk_number = disk_number
    self.priority = priority
  end

  def block_device
    (@vds.hvm? ? "hd" : "xvd") + ("a".ord + priority).chr
  end
end

ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :database => "#{AGENT_ROOT}/databases/cloud.sqlite"
)

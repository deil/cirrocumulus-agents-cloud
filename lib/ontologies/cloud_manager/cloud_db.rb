require 'active_support'
require 'active_record'
require 'guid'

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
  attr_accessor :is_running

  def initialize(id, vds_type, uid, ram)
    @id = id
    @vds_type = vds_type
    @uid = uid
    @current = VdsConfigurationHistory.new(ram)
    @disks = []
    @hvm = 0
    @is_running = 0
  end

  def hvm?
    hvm == 1
  end

  def is_running?
    is_running == 1
  end

  def start(origin = nil, agent = nil)
    self.is_running = 1
    save(origin, agent)
  end

  def stop(origin = nil, agent = nil)
    self.is_running = 0
    save(origin, agent)
  end

  def attach_disk(disk)
    prio = disks.size
    disks << disk
    disk.vds = self
    disk.priority = disks.size
    disk.save()
    save()
  end

  def self.active
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
        vds = self.find_by_uid(vds_uid)
        vdses << vds if vds.is_running?
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
    vds.is_running = json['is_running']
    vds.disks = json['disks'].map {|disk|
      d = VdsDisk.find_by_number(disk['number'])
      d.priority = disk['priority']
      d.vds = vds
      d
    } if json['disks']

    vds
  end
  
  def self.create_vds(ram)
    last_id = 0
    active.each {|vds| last_id = vds.id if vds.id > last_id}
    last_id += 1
    uid = Guid.new.to_s.gsub('-', '')
    vds = VpsConfiguration.new(last_id, "xen", uid, ram)
    vds.start()
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
    fact.save()
  end

  def delete()
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
  attr_accessor :number
  attr_accessor :priority
  attr_accessor :vds
  attr_accessor :size

  def initialize(vds, disk_number, priority, size = nil)
    @vds = vds
    self.number = disk_number
    self.priority = priority
    self.size = size
  end

  def block_device
    (@vds.hvm? ? "hd" : "xvd") + ("a".ord + priority).chr
  end

  def save(origin = nil, agent = nil)
    fact = KnownFact.current.find_by_key('vdisk_' + number.to_s)
    fact = KnownFact.new(:key => 'vdisk_' + number.to_s, :is_active => true) unless fact
    _vds = self.vds
    self.vds = nil
    fact.value = self.to_json
    self.vds = _vds
    fact.origin = origin
    fact.agent = agent
    fact.save()
  end

  def delete()
    fact = KnownFact.current.find_by_key('vdisk_' + number.to_s)
    fact.update_attributes(:is_active => false) if fact
  end
  
  def self.all
    disks = []
    KnownFact.all(:conditions => ['key like "vdisk_%%"']).each do |f|
      if f.key =~ /vdisk_(\d+)$/
        disk_number = $1.to_i
        disks << self.find_by_number(disk_number)
      end
    end

    disks
  end
  
  def self.find_by_number(disk_number)
    fact = KnownFact.current.find_by_key('vdisk_' + disk_number.to_s)
    return nil unless fact

    json = ActiveSupport::JSON.decode(fact.value)
    disk = VdsDisk.new(nil, disk_number, json['priority'], json['size'])
    disk
  end
  
  def self.create(size)
    last_number = 0
    all.each {|disk| last_number = disk.number if disk.number > last_number }
    d = self.new(nil, last_number + 1, 0, size)
    d.save()
    d
  end
end

ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :database => "#{AGENT_ROOT}/databases/cloud.sqlite"
)

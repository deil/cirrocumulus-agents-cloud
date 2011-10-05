require 'active_support'
require 'active_record'

class KnownFact < ActiveRecord::Base
  named_scope :current, :conditions => {:is_active => 1}
end

class VirtualDisk
  attr_reader :disk_number
  
  def initialize(disk_number)
    @disk_number = disk_number
  end

  def self.all
    disks = []
    KnownFact.all(:conditions => ['key like "md%%"']).each do |f|
      if f.key =~ /md(\d+)$/
        disk_number = $1.to_i
        disks << self.find_by_disk_number(disk_number)
      end
    end

    disks
  end

  def self.find_by_disk_number(disk_number)
    fact = KnownFact.current.find_by_key('md' + disk_number.to_s)
    return nil unless fact
    json = ActiveSupport::JSON.decode(fact.value)
    VirtualDisk.new(disk_number)
  end
  
  def save(origin = nil, agent = nil)
    fact = KnownFact.current.find_by_key('md' + @disk_number.to_s)
    fact = KnownFact.new(:key => 'md' + @disk_number.to_s, :is_active => 1) unless fact
    fact.value = self.to_json
    fact.origin = origin
    fact.agent = agent
    fact.save
  end

  def delete()
    fact = KnownFact.current.find_by_key('md' + @disk_number.to_s)
    fact.update_attributes(:is_active => false) if fact
  end

end

class DomUConfig
  attr_reader :name
  attr_accessor :is_hvm
  attr_accessor :ram
  attr_accessor :vcpus
  attr_accessor :cpu_weight
  attr_accessor :cpu_cap
  attr_accessor :disks
  attr_accessor :eth0_mac
  attr_accessor :eth1_mac
  attr_accessor :vnc_port
  attr_accessor :boot_device

  def initialize(name)
    @name = name
  end

  def save(origin = nil, agent = nil)
    fact = KnownFact.current.find_by_key('domu_' + self.name)
    fact = KnownFact.new(:key => 'domu_' + self.name, :is_active => 1) unless fact
    fact.value = self.to_json
    fact.origin = origin
    fact.agent = agent
    fact.save
  end

  def delete()
    fact = KnownFact.current.find_by_key('domu_' + self.name)
    fact.update_attributes(:is_active => false) if fact
  end

  def self.all
    domus = []
    KnownFact.all(:conditions => ['key like "domu_%%"']).each do |f|
      if f.key =~ /domu_(\w+)$/
        domu_name = $1
        domus << self.find_by_name(domu_name)
      end
    end

    domus
  end

  def self.find_by_name(name)
    fact = KnownFact.current.find_by_key('domu_' + name)
    return nil unless fact
    json = ActiveSupport::JSON.decode(fact.value)
    domU = DomUConfig.new(name)
    domU.is_hvm = json['is_hvm']
    domU.ram = json['ram']
    domU.vcpus = json['vcpus']
    domU.cpu_weight = json['cpu_weight']
    domU.cpu_cap = json['cpu_cap']
    domU.disks = json['disks'] # TODO
    domU.eth0_mac = json['eth0_mac']
    domU.eth1_mac = json['eth1_mac']
    domU.vnc_port = json['vnc_port']
    domU.boot_device = json['boot_device']
    return domU
  end
end

class GuestState
  attr_reader :name
  attr_accessor :is_up
  
  def initialize(name, is_up)
    @name = name
    @is_up = is_up
  end
  
  def self.find_by_name(name)
    fact = KnownFact.current.find_by_key('domu_' + name + '-state')
    return nil unless fact
    GuestState.new(name, fact.value == 'running')
  end
  
  def save(origin = nil, agent = nil)
    fact = KnownFact.current.find_by_key('domu_' + name + '-state')
    fact = KnownFact.new(:key => 'domu_' + name + '-state', :is_active => 1) unless fact
    fact.value = @is_up ? 'running' : 'stopped'
    fact.origin = origin
    fact.agent = agent
    fact.save
  end
  
  def delete()
    fact = KnownFact.current.find_by_key('domu_' + name + '-state')
    fact.update_attributes(:is_active => false) if fact
  end
end

ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :database => "#{AGENT_ROOT}/databases/xen.sqlite"
)

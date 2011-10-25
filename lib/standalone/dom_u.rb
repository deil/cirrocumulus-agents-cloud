require 'erb'

class DomU
  attr_accessor :name
  attr_accessor :type
  attr_accessor :ram
  attr_accessor :vcpus
  attr_accessor :disks
  attr_accessor :cpu_weight
  attr_accessor :cpu_cap
  attr_accessor :vnc_port
  attr_accessor :network_boot
  attr_accessor :bridge
  attr_reader :ethernets

  def initialize(name, type, ram)
    self.name = name
    self.type = type
    self.ram = ram
    self.vcpus = 1
    self.disks = []
    self.cpu_weight = ram
    self.cpu_cap = 0
    self.bridge = XEN_CONFIG[:default_bridge]
    self.ethernets = []
  end
  
  def eth0_mac
    return ethernets && ethernets.size > 0 ? ethernets[0] : nil
  end

  def eth1_mac
    return ethernets && ethernets.size > 1 ? ethernets[1] : nil
  end

  def to_xml
    template_file = File.open(File.join(AGENT_ROOT, "standalone/domU_#{self.type.to_s}.xml"))
    template = template_file.read()
    template_file.close()

    xml = ERB.new(template)
    xml.result(binding)
  end
end

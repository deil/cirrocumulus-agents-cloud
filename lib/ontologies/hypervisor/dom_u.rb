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
  attr_accessor :default_bridge
  attr_accessor :ethernets

  def initialize(name, type, ram)
    self.name = name
    self.type = type
    self.ram = ram
    self.vcpus = 1
    self.disks = []
    self.cpu_weight = ram
    self.cpu_cap = 0
    self.default_bridge = XEN_CONFIG[:default_bridge]
    self.ethernets = []
  end
  
  def to_xml
    template_file = File.open(File.join(AGENT_ROOT, "standalone/domU_#{self.type.to_s}.xml"))
    template = template_file.read()
    template_file.close()

    xml = ERB.new(template)
    xml.result(binding)
  end
end

require 'erb'

class DomU
  attr_accessor :name
  attr_accessor :mem
  attr_accessor :vcpus
  attr_accessor :disks
  attr_accessor :cpu_weight
  attr_accessor :cpu_cap
  attr_accessor :eth0_mac
  attr_accessor :eth1_mac
  attr_accessor :vnc_port

  def initialize(name, mem, vcpus, disks, cpu_weight, cpu_cap)
    @name = name
    @mem = mem
    @vcpus = vcpus
    @disks = disks
    @cpu_weight = cpu_weight
    @cpa_cap = cpu_cap
    #@eth0_mac = "00:16:3e:1b:00:#{@id.to_s(16)}"
    #@eth1_mac = "00:16:3e:1b:a0:#{@id.to_s(16)}"
    #@vnc_port = 5900 + @id
  end

  def to_xml
    template_file = File.open(File.join(AGENT_ROOT, 'standalone/domU.xml'))
    template = template_file.read()
    template_file.close()

    xml = ERB.new(template)
    xml.result(binding)
  end
end

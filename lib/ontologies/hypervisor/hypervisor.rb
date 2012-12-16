require 'libvirt'

class Hypervisor
  class << self
    def connect
      @@libvirt = Libvirt::open
    end

    def close
      @@libvirt.close
    end

    def free_memory
      @@libvirt.node_free_memory / (1024*1024)
    end

    def set_cpu(domU, weight, cap)
      cmd = "xm sched-credit -d #{domU} -w #{weight} -c #{cap}"
      _, res = systemu(cmd)
    end

    def list_running_guests
      guests = @@libvirt.list_domains().map {|dom_id| @@libvirt.lookup_domain_by_id(dom_id).name}
      guests.shift
      guests
    end
  end
end

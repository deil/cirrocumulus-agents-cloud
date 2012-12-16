require 'libvirt'
require_relative 'libvirt_domain'

class Hypervisor
  class << self
    def connect
      @@libvirt = Libvirt::open
    end

    def close
      @@libvirt.close
    end

    def total_memory
      @@libvirt.node_get_info.memory / 1024
    end

    def free_memory
      @@libvirt.node_free_memory / (1024*1024)
    end

    def set_cpu(domU, weight, cap)
      cmd = "xm sched-credit -d #{domU} -w #{weight} -c #{cap}"
      _, res = systemu(cmd)
    end

    def running_guests
      guests = @@libvirt.list_domains().map {|dom_id| @@libvirt.lookup_domain_by_id(dom_id).name}
      guests.shift
      guests
    end

    def is_guest_running?(guest_id)
      @@libvirt.lookup_domain_by_name(guest_id)
    rescue
      false
    end

    def find(guest_id)
      if is_guest_running?(guest_id)
        d = @@libvirt.lookup_domain_by_name(guest_id)
        d_info = d.info
        domain = LibvirtDomain.new(guest_id)
        domain.vcpus = d_info.nr_virt_cpu
        domain.memory = d_info.memory
        domain.cpu_time = (d_info.cpu_time / 10000000).round()/100.0

        (0..3).each do |i|
          begin
            vif_name = "vif%d.%d" % [d.id, i]
            vif_info = d.ifinfo(vif_name)
            domain.interfaces << {:tx => vif_info.tx_bytes, :rx => vif_info.rx_bytes}
          rescue
          end
        end

        ('a'..'z').each do |x|
          stats = nil
          begin
            stats = d.block_stats("xvd%s" % x)
          rescue; end

          begin
            stats = d.block_stats("hd%s" % x)
          rescue; end

          domain.block[x] = {
              :rd_bytes => stats.rd_bytes,
              :rd_req => stats.rd_req,
              :wr_bytes => stats.wr_bytes,
              :wr_req => stats.wr_req
          } if stats
        end

        return domain
      end

      nil
    end
  end
end

require 'systemu'
require 'libvirt'
require_relative 'libvirt_domain.rb'

class XenNode
  def self.list_running_guests()
    guests = @@libvirt.list_domains().map {|dom_id| @@libvirt.lookup_domain_by_id(dom_id).name}
    guests.shift
    guests
  end

  def self.is_guest_running?(guest_id)
    @@libvirt.lookup_domain_by_name(guest_id)
  rescue
    false
  end

  def self.find(guest_id)
    if self.is_guest_running?(guest_id)
      d = @@libvirt.lookup_domain_by_name(guest_id)
      d_info = d.info
      domain = LibvirtDomain.new(guest_id)
      domain.vcpus = d_info.nr_virt_cpu
      domain.memory = d_info.memory
      domain.cpu_time = d_info.cpu_time

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
          stats = d.blockstats("xvd%s" % x)
        rescue; end

        begin
          stats = d.blockstats("hd%s" % x)
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

  def self.total_vcpus
    @@libvirt.node_get_info.cpus
  end
  
  def self.total_mhz
    info = @@libvirt.node_get_info
    info.cpus * info.mhz
  end
  
  def self.total_memory
    @@libvirt.node_get_info.memory / 1024
  end

  def self.free_memory
    @@libvirt.node_free_memory / (1024*1024)
  end

  def self.get_cpu(domU)
    _, res = systemu "virsh schedinfo #{domU}"
    list = res.split("\n")
    weight = list[1].split(" ")[2].to_i
    cap = list[2].split(" ")[2].to_i

    [weight, cap]
  end

  def self.set_cpu(domU, weight, cap)
    cmd = "xm sched-credit -d #{domU} -w #{weight} -c #{cap}"
    Log4r::Logger['os'].debug(cmd)
    _, res = systemu(cmd)
  end

  def self.get_memory(domU)
    _, res = systemu "xm list"
    list = res.split("\n")
    list.each do |vm|
      uid = vm.split(' ')[0]
      mem = vm.split(' ')[2]

      return mem.to_i if uid == domU
    end
  end

  def self.start(xml_config)
    cmd = "virsh create #{xml_config}"
    puts cmd
    _, out, err = systemu(cmd)
    puts out
    puts err
    
    err.blank?
  end

  def self.start_guest(domU_config)
    xml_config = File.join(AGENT_ROOT, "domu_#{domU_config.name}.xml")
    xml = File.open(xml_config, "w")
    xml.write(domU_config.to_xml)
    xml.close

    cmd = "virsh create #{xml_config}"
    perform_cmd(cmd)
  end

  def self.reboot_guest(guest_id)
    perform_cmd("virsh reboot #{guest_id}")
  end

  def self.stop_guest(guest_id)
    perform_cmd("virsh destroy #{guest_id}")
  end
  
  def self.attach_disk(domU, disk_number, block_device)
    cmd = "virsh attach-disk #{domU} /dev/md#{disk_number} #{block_device}"
    puts cmd
    _, res, err = systemu(cmd)
    err.blank?
  end
  
  def self.detach_disk(domU, block_device)
    cmd = "virsh detach-disk #{domU} #{block_device}"
    puts cmd
    _, res, err = systemu(cmd)
    err.blank?
  end
  
  def self.connect()
    @@libvirt = Libvirt::open()
  end
  
  def self.close()
    @@libvirt.close()
  end

  private

  def self.perform_cmd(cmd, log_output = true)
    Log4r::Logger['os'].debug(cmd) if log_output
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out.strip) if log_output
    Log4r::Logger['os'].debug(err.strip) if log_output

    err.blank?
  end
end

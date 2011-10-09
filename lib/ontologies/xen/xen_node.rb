require 'systemu'

class XenNode
  def self.list_running_guests()
    domus = []

    _, res = systemu 'virsh list'
    list = res.split("\n")
    list.each_with_index do |item,idx|
      next if idx < 3
      items = item.split(' ')
      domU = items[1]
      domus << domU
    end

    domus
  end

  def self.is_guest_running?(guest_id)
    return list_running_guests.include? guest_id
  end

  def self.total_vcpus
    _, res = system('virsh nodeinfo')
    res =~ /CPU\(s\): +(\d)/
    $1.to_i
  end
  
  def self.total_mhz
    _, res = system('virsh nodeinfo')
    res =~ /CPU frequency: +(\d+) MHz/
    vcpu_mhz = $1.to_i
    total_vcpus * vcpu_mhz
  end
  
  def self.total_memory
    _, res = systemu('virsh nodeinfo')
    res =~ /Memory size: +(\d+) kB/
    $1.to_i / 1024
  end

  def self.free_memory
    _, res = systemu 'virsh freecell'
    res.split(' ')[1].to_i / 1024
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

  private

  def perform_cmd(cmd)
    Log4r::Logger['os'].debug(cmd)
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out)
    Log4r::Logger['os'].debug(err)

    err.blank?
  end
end

require 'systemu'

class Mdraid
  def self.list_volumes()
    Log4r::Logger['os'].debug('cat /proc/mdstat | grep "active raid1"')
    `cat /proc/mdstat | grep "active raid1"`.split("\n").map {|l| l.split(' ').first}
  end

  def self.list_disks()
    volumes = self.list_volumes()
    res = []
    volumes.each do |v|
      if v =~ /md\d/
        res << v.gsub('md', '').to_i
      end
    end

    res
  end

  def self.get_status(disk_number)
    cmd = "mdadm --detail /dev/md#{disk_number}"
    Log4r::Logger['os'].debug(cmd)
    _, out, err = systemu(cmd)
    return :stopped unless err.blank?
    return :active if out.include?('clean') || out.include?('active')
    :failed
  end

  def self.degraded?(disk_number)
    cmd = "mdadm --detail /dev/md#{disk_number}"
    _, out, err = systemu(cmd)
    return out.include?('degraded') ? true : false
  end

  def self.recovering?(disk_number)
    cmd = "mdadm --detail /dev/md#{disk_number}"
    _, out, err = systemu(cmd)
    return out.include?('recovering') || out.include?('resyncing') ? true : false
  end
  
  def self.create(disk_number)
    exports = check_aoe(disk_number)
    devices = exports_to_aoe_devices(exports)
    devices << "missing" if exports.size < 2
    cmd = "mdadm --create /dev/md#{disk_number} --force --run --level=1 --raid-devices=2 -binternal --bitmap-chunk=1024 --metadata=1.2 " + devices.join(' ')
    Log4r::Logger['os'].info(cmd)
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out.strip)
    Log4r::Logger['os'].debug(err.strip)

    err =~ /array \/dev\/md#{disk_number} started/
  end

  def self.assemble(disk_number)
    exports = check_aoe(disk_number)
    devices = exports_to_aoe_devices(exports)
    cmd = "mdadm --assemble /dev/md#{disk_number} " + devices.join(' ') + " --run"
    Log4r::Logger['os'].debug(cmd)
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out.strip)
    Log4r::Logger['os'].debug(err.strip)
    err.blank? || err.include?("has been started")
  end

  def self.stop(disk_number)
    cmd = "mdadm -S /dev/md#{disk_number}"
    Log4r::Logger['os'].debug(cmd)
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out.strip)
    Log4r::Logger['os'].debug(err.strip)
    return err.blank? || err.include?("stopped ")
  end

  def self.check_aoe(disk_number)
    exports = []
    cmd = "aoe-stat"
    Log4r::Logger['os'].debug(cmd)
    _, res = systemu(cmd)
    lines = res.split("\n")
    lines.each do |line|
      l = line.split(" ")
      if l.first =~ /e#{disk_number}\.\d/
        exports << l.first if l[4] == 'up'
      end
    end

    exports
  end

  attr_reader :disk_number
  
  def initialize(disk_number)
    @disk_number = disk_number
    refresh()
  end

  def refresh
    cmd = "mdadm --detail /dev/md#{self.disk_number}"
    _, out, err = systemu(cmd)
    @error = !err.empty?
    @data = out.split("\n")
  end

  def number_of_devices
    item = @data.find {|l| l =~ /Raid Devices : (\d)/}
    return item.empty? ? 0 : $1.to_i
  end

  def number_of_active_devices
    item = @data.find {|l| l =~ /Active Devices : (\d)/}
    return item.empty? ? 0 : $1.to_i
  end

  def clean?
    item = @data.find {|l| l =~ /State : ([\w ,]+)$/}
    if !item.empty?
      states = item.split(', ')

      return false if states.include?('recovering')
      return false if states.include?('resyncing')
      return false if states.include?('degraded')
    end

    true
  end

  def initializing?
    item = @data.find {|l| l =~ /State : ([\w ,]+)$/}
    if !item.empty?
      states = item.split(', ')

      return true if !states.include?('degraded') && states.include?('resyncing')
    end

    false
  end

  def degraded?
    item = @data.find {|l| l =~ /State : ([\w ,]+)$/}
    if !item.empty?
      states = item.split(', ')

      return true if states.include?('degraded')
    end

    false
  end

  def failed_devices
    devices = []
    @data.each do |l|
      if l =~ /faulty spare\s+\/dev\/etherd\/e(\d+)\.(\d)$/
        devices << "e#{$1}.#{$2}"
      end
    end

    devices
  end

  def aoe_devices
    cmd = "cat /proc/mdstat | grep md#{disk_number}"
    Log4r::Logger['os'].debug(cmd)
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out.strip)
    results = out.scan /etherd\/e#{disk_number}\.(\d)/
    results.map {|r| "e%d.%s" % [disk_number, r.first]}
  end
  
  def component_up?(device)
    cmd = "cat /proc/mdstat | grep md#{disk_number}"
    Log4r::Logger['os'].debug(cmd)
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out.strip)
    return (out =~ /#{device}\[\d\]\(F\)/).nil?
  end

  private

  def self.exports_to_aoe_devices(exports)
    exports.map {|e| '/dev/etherd/' + e}
  end
end

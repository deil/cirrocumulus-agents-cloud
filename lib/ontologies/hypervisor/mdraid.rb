require 'systemu'

class Mdraid
  class << self
    def readd_exports(storage_number)
      puts "Re-adding exports from storage #{storage_number}"
      processed = 0

      self.list_disks.each do |disk_number|
        md = Mdraid.new(disk_number)
        device = "e#{disk_number}.#{storage_number}"
        if !md.component_up?(device)
          if md.aoe_devices.include?(device)
            md.remove(device)
          end

          md.add(device)
          processed += 1
        end
      end

      puts "Done re-adding exports. Updated #{processed} disks"
    end

    def fail_exports(storage_number)
      puts "Failing exports from storage #{storage_number}"
    end
  end

  def self.list_volumes()
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
    _, out, err = systemu(cmd)

    err =~ /array \/dev\/md#{disk_number} started/
  end

  def self.assemble(disk_number, exports)
    devices = exports_to_aoe_devices(exports)
    cmd = "mdadm --assemble /dev/md#{disk_number} " + devices.join(' ') + " --run"
    _, out, err = systemu(cmd)

    if err.blank? || err.include?("has been started")
      return self.new(disk_number)
    end

    nil
  end

  def self.stop(disk_number)
    cmd = "mdadm -S /dev/md#{disk_number}"
    _, out, err = systemu(cmd)
    return err.blank? || err.include?("stopped ")
  end

  def self.check_aoe(disk_number)
    exports = []
    cmd = "aoe-stat"
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
      item =~ /State : ([\w ,]+)$/
      states = $1.split(', ')
      return true if states.include?('active') || states.include?('clean')
    end

    false
  end

  def initializing?
    item = @data.find {|l| l =~ /State : ([\w ,]+)$/}
    if !item.empty?
      item =~ /State : ([\w ,]+)$/
      states = $1.split(', ')
      return true if !states.include?('degraded') && states.include?('resyncing')
    end

    false
  end

  def degraded?
    item = @data.find {|l| l =~ /State : ([\w ,]+)$/}
    if !item.empty?
      item =~ /State : ([\w ,]+)$/
      states = $1.split(', ')
      return true if states.include?('degraded')
    end

    false
  end

  def recovering?
    item = @data.find {|l| l =~ /State : ([\w ,]+)$/}
    if !item.empty?
      item =~ /State : ([\w ,]+)$/
      states = $1.split(', ')
      return true if states.include?('recovering')
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
    result = []
    marker_found = false
    (21..@data.size-1).each do |idx|
      line = @data[idx].split(' ')
      marker_found = true if line.size == 5 && line[0] == 'Number' && line[4] == 'State'

      next unless marker_found

      line = @data[idx].split(/ {2,}/)
      next if line.size < 7

      raid_device = line[6]
      raid_device = File.readlink(raid_device) if raid_device =~ /\/dev\/block\//
      aoe_device = raid_device.scan /etherd\/e#{self.disk_number}\.(\d)/
      result << "e#{self.disk_number}.#{aoe_device[0][0]}"
    end

    result
  end
  
  def component_up?(device)
    marker_found = false
    (21..@data.size-1).each do |idx|
      line = @data[idx].split(' ')
      marker_found = true if line.size == 5 && line[0] == 'Number' && line[4] == 'State'

      next unless marker_found

      line = @data[idx].split(/ {2,}/)
      next if line.size < 7

      raid_device = line[6]
      raid_device = File.readlink(raid_device) if raid_device =~ /\/dev\/block\//

      if raid_device =~ Regexp.new(device)
        return true if line[5] != 'faulty spare'
      end
    end

    false
  end

  def add(aoe_device)
    cmd = "mdadm /dev/md#{self.disk_number} --add /dev/etherd/#{aoe_device}"
    puts cmd
    system(cmd)
  end

  def fail(aoe_device)
    cmd = "mdadm /dev/md#{self.disk_number} --fail /dev/etherd/#{aoe_device}"
    puts cmd
    system(cmd)
  end

  def remove(aoe_device)
    cmd = "mdadm /dev/md#{self.disk_number} --remove /dev/etherd/#{aoe_device}"
    puts cmd
    system(cmd)
  end

  private

  def self.exports_to_aoe_devices(exports)
    exports.map {|e| '/dev/etherd/' + e}
  end
end

require 'systemu'

class Mdraid
  def self.list_volumes()
    Log4r::Logger['os'].debug('cat /proc/mdstat | grep "active raid1"')
    `cat /proc/mdstat | grep "active raid1"`.map {|l| l.split(' ').first}
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

  def self.check_status(disk_number)
    cmd = "cat /proc/mdstat | grep md#{disk_number}"
    Log4r::Logger['os'].debug(cmd)
    _, res = systemu(cmd)
    lines = res.split("\n")
    return :stopped if lines.blank?

    line = lines.first
    return line.split(" ")[2] == "active" ? :active : :failed
  end

  def self.assemble(disk_number)
    exports = check_aoe(disk_number)
    devices = exports_to_aoe_devices(exports)
    cmd = "mdadm --assemble /dev/md#{disk_id} " + devices.join(' ') + " --run"
    Log4r::Logger['os'].debug(cmd)
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out)
    Log4r::Logger['os'].debug(err)
    err.blank? || err.include?("has been started")
  end

  private

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

  def self.exports_to_aoe_devices(exports)
    exports.map {|e| '/dev/etherd/' + e}
  end
end

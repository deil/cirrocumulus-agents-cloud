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

  def self.get_status(disk_number)
    #cmd = "cat /proc/mdstat | grep md#{disk_number}"
    cmd = "mdadm --detail /dev/md#{disk_number}"
    Log4r::Logger['os'].debug(cmd)
    _, out, err = systemu(cmd)
    return :stopped unless err.blank?
    return :failed if out.include? 'degraded'
    :active
  end

  def self.create(disk_number)
    exports = check_aoe(disk_number)
    devices = exports_to_aoe_devices(exports)
    devices << "missing" if exports.size < 2
    cmd = "mdadm --create /dev/md#{disk_number} --force --run --level=1 --raid-devices=2 -binternal --bitmap-chunk=1024 --metadata=1.2 " + devices.join(' ')
    Log4r::Logger['os'].info(cmd)
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out)
    Log4r::Logger['os'].debug(err)

    err =~ /array \/dev\/md#{disk_number} started/
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

  def self.stop(disk_number)
    cmd = "mdadm -S /dev/md#{disk_number}"
    Log4r::Logger['os'].debug(cmd)
    _, out, err = systemu(cmd)
    Log4r::Logger['os'].debug(out)
    Log4r::Logger['os'].debug(err)
    return err.blank? || err.include?("stopped ")
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

require 'hdd.rb'

class HddAutodiscover
  def initialize(volume_name)
    @vg_name = volume_name
  end

  def collect
    result = {}

    pvs = `/sbin/pvs`
    pvs.split("\n").each do |l|
      a = l.split(' ')
      next if a[1] != @vg_name

      result[:lvm] = {:pv => a[0], :free => a[5].to_f*1024}
      result[:mdadm] = {}
      mdadm = `/sbin/mdadm --detail #{result[:lvm][:pv]}`
      found = false
      mdadm.split("\n").each do |md_l|
        md_a = md_l.split(' ')
        if md_a[0] == 'State'
          result[:mdadm][:state] = md_a[2]
        elsif md_a[0] == 'Failed'
          result[:mdadm][:failed_devices] = md_a[3].to_i
        elsif md_a[0] == 'Number'
          found = true
          result[:mdadm][:devices] = []
        elsif found
          result[:mdadm][:devices] << md_a[6]
        end
      end

      break
    end

    result[:hdd] = []
    result[:mdadm][:devices].each do |part|
      test = part =~ /\/dev\/(sd.)\d/
      if test
        result[:hdd] << HDD.new($1)
      end
    end

    result
  end
end

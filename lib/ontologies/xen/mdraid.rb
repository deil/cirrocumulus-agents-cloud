require 'systemu'

class Mdraid
  def self.list_volumes()
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
end

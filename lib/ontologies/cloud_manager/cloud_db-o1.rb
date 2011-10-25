require 'mysql2'
require 'active_record'

ActiveRecord::Base.establish_connection(
  :adapter => 'mysql2',
  :host => '172.16.11.5',
  :username => 'o1host',
  :password => 'o1h0st',
  :database => "o1_panel",
  :encoding => 'utf8'
)

class VpsConfiguration < ActiveRecord::Base
  def self.running
    candidates = all(:conditions => {:is_active => true})
    candidates.select {|v| v.current.running?}
  end
  
  def current
    VpsConfigurationHistory.first(:conditions => {:vps_id => vps_id}, :order => 'timestamp desc')
  end

  def disks
    StorageDisksVpsConfiguration.all(:conditions => {:vps_configuration_id => id}, :order => 'priority asc')
  end
end

class VpsConfigurationHistory < ActiveRecord::Base
end

class StorageDisk < ActiveRecord::Base
end

class StorageDiskHistory < ActiveRecord::Base
end

class StorageDisksVpsConfiguration < ActiveRecord::Base
  belongs_to :vps_configuration
  belongs_to :storage_disk

  def disk_number
    storage_disk.disk_number
  end

  def block_device
    (vps_configuration.hvm? ? "hd" : "xvd") + ("a".ord + priority).chr
  end
end

class LibvirtDomain
  attr_reader :uid

  attr_accessor :vcpus
  attr_accessor :memory
  attr_accessor :cpu_time
  attr_reader :interfaces
  attr_reader :block

  def initialize(uid)
    @uid = uid
    @interfaces = []
    @block = {}
  end
end

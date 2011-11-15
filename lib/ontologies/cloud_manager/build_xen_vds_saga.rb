class BuildXenVdsSaga < Saga
  attr_reader :vds

  def start(vds)
    @vds = vds
  end

  def handle(message = nil)

  end
end

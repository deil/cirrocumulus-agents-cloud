class StartVirtualDiskSaga < Saga
  attr_reader :disk_number

  def start(disk_number, message = nil)
    @original_message = message
    @disk_number = disk_number

    Log4r::Logger['kb'].info "++ Starting saga #{id}: Activate VD #{self.disk_number}."
    handle()
  end

  def handle(message = nil)
    finish()
  end
end

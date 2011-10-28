require 'guid'

class CreateXenVdsSaga < Saga
  attr_reader :vds_config

  def start(vds_config, message)
    @vds_config = vds_config
    handle()
  end

  protected

  def handle(message = nil)
    case @state
      when STATE_START then
        Log4r::Logger['agent'].info "[#{id}] Creating new Xen VDS with RAM=#{vds_config[:ram]}Mb"
        finish()
    end
  end

end

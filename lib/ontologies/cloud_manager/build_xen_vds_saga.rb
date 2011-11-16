require File.join(AGENT_ROOT, 'standalone/mac.rb')

class BuildXenVdsSaga < Saga
  attr_reader :vds

  def start(vds)
    @vds = vds
    @ontology.engine.replace [:vds, :VDS, :actual_state, :CREATED], :building
    handle()
  end

  def handle(message = nil)
    case @state
      when STATE_START
        Log4r::Logger['agent'].info "[#{id}] Building VDS #{vds.uid} with #{vds.current.ram}Mb RAM"
        eth0_mac = MAC.generate(1, vds.id, 0)
        eth1_mac = MAC.generate(1, vds.id, 1)
        Log4r::Logger['agent'].debug "[#{id}] eth0 MAC is #{eth0_mac}"
        Log4r::Logger['agent'].debug "[#{id}] eth1 MAC is #{eth1_mac}"
        finish()
    end
  end

  protected

end

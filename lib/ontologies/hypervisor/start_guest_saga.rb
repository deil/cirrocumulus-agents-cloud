class StartGuestSaga < Saga
  def start(guest_cfg, logger, sender, contents, options)
    @guest_cfg = guest_cfg
    @sender = sender
    @contents = contents
    @options = options
    @logger = logger

    logger.info "Starting saga #{id}: start guest #{@guest_cfg[:id]} with RAM #{@guest_cfg[:ram]} Mb"
    timeout(1)
  end

  def handle_reply(sender, contents, options = {})
    if !parameters_are_correct
      @ontology.refuse(@sender, @contents, [:incorrect_parameters], @options) and return
    end

    begin
      guest = DomU.new(guest_id, guest_cfg[:is_hvm] == 1 ? :hvm : :pv, guest_cfg[:ram])
      guest.vcpus = guest_cfg[:cpu][:num]
      guest.disks = guest_cfg[:disks]
      guest.cpu_weight = guest_cfg[:cpu][:weight]
      guest.cpu_cap = guest_cfg[:cpu][:cap]
      guest.interfaces = guest_cfg[:ifaces]
      guest.network_boot = guest_cfg[:network_boot]
      guest.vnc_port = guest_cfg[:vnc][:port] if guest_cfg[:vnc][:port]

      xml_config = "domu_#{guest_id}.xml"
      xml = File.open(xml_config, 'w')
      xml.write(guest.to_xml)
      xml.close
    rescue Exception => ex
      logger.error ex.to_s
      @ontology.failure(@sender, @contents, [:unknown_reason], @options)
    end


    @ontology.agree(@sender, @contents, @options)
  end

  protected

  def parameters_are_correct
    false
  end

end

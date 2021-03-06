require_relative 'hypervisor'
require_relative 'mdraid'

class StartGuestSaga < Saga
  def start(guest_cfg, logger, sender, contents, options)
    @guest_cfg = guest_cfg
    @sender = sender
    @contents = contents
    @options = options
    @logger = logger

    @logger.info "Starting saga #{id}: start guest #{@guest_cfg[:id]} with RAM #{@guest_cfg[:ram]} Mb"
    timeout(1)
  end

  def handle_reply(sender, contents, options = {})
    if !parameters_are_correct
      @logger.error 'Incorrect guest parameters were supplied. Stop'
      @ontology.refuse(@sender, @contents, [:incorrect_parameters], @options)
      error and return
    end

    @logger.debug 'Supplied guest parameters are correct'

    if Hypervisor.is_guest_running?(@guest_cfg[:id])
      @logger.warn "Guest #{@guest_cfg[:id]} is already running"
      @ontology.refuse(@sender, @contents, [:guest_already_running], @options)
      finish and return
    end

    @logger.debug "#{Hypervisor.free_memory}Mb RAM is available, #{@guest_cfg[:ram]}Mb is required"
    if Hypervisor.free_memory <= @guest_cfg[:ram]
      @logger.error 'No free RAM to start this guest'
      @ontology.refuse(@sender, @contents, [:insufficient_ram], @options)
      error and return
    end

    if !all_disks_available
      @logger.error 'Not all virtual disks are available. Stop'
      error and return
    end

    @logger.debug 'Generating libvirt config and starting guest'

    guest = DomU.new(@guest_cfg[:id], @guest_cfg[:is_hvm] == 1 ? :hvm : :pv, @guest_cfg[:ram])
    guest.vcpus = @guest_cfg[:cpu][:num]
    guest.disks = @guest_cfg[:disks]
    guest.cpu_weight = @guest_cfg[:cpu][:weight]
    guest.cpu_cap = @guest_cfg[:cpu][:cap]
    guest.interfaces = @guest_cfg[:ifaces]
    guest.network_boot = @guest_cfg[:network_boot]
    guest.vnc_port = @guest_cfg[:vnc][:port] if @guest_cfg[:vnc][:port] > 0

    xml_config = "domu_#{@guest_cfg[:id]}.xml"
    xml = File.open(xml_config, 'w')
    xml.write(guest.to_xml)
    xml.close

    if Hypervisor.start_from_file(@guest_cfg[:id])
      @logger.info 'Setting weight & cap'
      Hypervisor.set_cpu(@guest_cfg[:id], @guest_cfg[:cpu][:weight], @guest_cfg[:cpu][:cap])

      @logger.info "Guest #{@guest_cfg[:id]} was successfully started."

      @ontology.agree(@sender, @contents, @options)
      finish
    else
      @logger.error 'Failed to start guest with unknown reason.'
      @ontology.failure(@sender, @contents, [:unknown_reason], @options)
      error
    end
  rescue Exception => ex
    @logger.error "Unhandled exception: #{ex.to_s}\n#{ex.backtrace.to_s}"
    @ontology.failure(@sender, @contents, [:unknown_reason], @options)
    error
  end

  protected

  def parameters_are_correct
    return false if @guest_cfg[:id].blank?
    return false if @guest_cfg[:ram].nil? || @guest_cfg[:ram] <= 0
    return false if @guest_cfg[:disks].size == 0 && @guest_cfg[:ifaces].size == 0

    true
  end

  def all_disks_available
    @guest_cfg[:disks].each do |disk|
      @logger.debug "Checking state of virtual disk #{disk[:number]}"
      if Mdraid.get_status(disk[:number]) != :stopped
        raid = Mdraid.new(disk[:number])
        return false unless raid.clean?
      end
    end

    true
  end

end

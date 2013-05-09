class StartGuestSaga < Saga
  def start(guest_cfg, sender, contents, options)
    @guest_cfg = guest_cfg
    @sender = sender
    @contents = contents
    @options = options

    logger.info "Starting saga #{id}: start guest #{@guest_cfg[:id]} with RAM #{@guest_cfg[:ram]} Mb"
    timeout(1)
  end

  def handle_reply(sender, contents, options = {})
    if !parameters_are_correct
      refuse(@sender, @contents, :incorrect_parameters) and return
    end

    agree(@sender, @contents)
  end

  protected

  def parameters_are_correct
    false
  end

end

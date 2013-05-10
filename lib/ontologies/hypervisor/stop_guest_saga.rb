require 'hypervisor'

class StopGuestSaga < Saga
  def start(guest_id, logger, sender, contents, options)
    @guest_id = guest_id
    @logger = logger
    @sender = sender
    @contents = contents
    @options = options

    @logger.info "Starting saga #{id}: shutdown guest #{guest_id}"
    timeout(1)
  end

  def handle_reply(sender, contents, options = {})
    if Hypervisor.is_guest_running?(@guest_id)
      if Hypervisor.destroy(@guest_id)
        @logger.info 'Guest was destroyed successfully.'
        @ontology.agree(@sender, @contents, @options) and finish
      else
        @logger.error 'Failed to stop guest with unknown reason.'
        @ontology.failure(@sender, @contents, [:unknown_reason], @options) and error
      end
    else
      @logger.warn 'Guest is not running. Stop'
      @ontology.refuse(@sender, @contents, [:guest_not_running], @options) and finish
    end
  rescue Exception => ex
    @logger.error "Unhandled exception: #{ex.to_s}\n#{ex.backtrace.to_s}"
    @ontology.failure(@sender, @contents, [:unknown_reason], @options)
    error
  end
end

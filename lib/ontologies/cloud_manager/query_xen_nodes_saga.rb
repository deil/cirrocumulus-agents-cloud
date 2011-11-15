class QueryXenNodesSaga < Saga
  def start()
    handle()
  end
  
  def handle(message = nil)
    case @state
      when STATE_START
        finish()
    end
  end
  
  protected
  
  
end
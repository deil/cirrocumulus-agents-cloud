require 'cirrocumulus/kb'

class DomUKb < Kb
  def collect_knowledge()
    @knowledge = []
    domUs = XenNode::list_running_domUs()
    domUs.each do |domU|
      add_fact([:running, [:domu, domU]], 'yes')
    end

    add_fact([:free_memory], XenNode::free_memory)
    add_fact([:domus_running], XenNode::list_running_domUs().size)
  end
end

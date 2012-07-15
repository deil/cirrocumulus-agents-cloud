require 'systemu'

class Aoe
  def initialize
    cmd = 'aoe-stat'
    _, res = systemu(cmd)
    @lines = res.split("\n")
  end

  def exports(disk_number)
    result = []
    @lines.each do |line|
      l = line.split(" ")
      if l.first =~ /e#{disk_number}\.(\d)/
        result << $1 if l[4] == 'up'
      end
    end

    result
  end

  private

  def perform_cmd(cmd, log_output = true)
    Log4r::Logger['agent'].debug "Executing command: #{cmd}" if log_output
    _, out, err = systemu(cmd)
    Log4r::Logger['agent'].debug "Result: #{out.strip}" if !out.strip.blank? && log_output
    Log4r::Logger['agent'].debug "Error: #{err.strip}" if !err.strip.blank? && log_output

    err.blank?
  end

end

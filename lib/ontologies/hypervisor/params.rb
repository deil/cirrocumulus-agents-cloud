module ParamsParser
  def self.guest_config(content)
    if content.size == 1 && content[0].is_a?(Array)
      content = content[0]
    end

    if content[0] == :guest
      guest = {
          cpu: {
              num: 1,
              cap: 0,
              weight: 128
          },
          hvm: 0,
          disks: [],
          ifaces: [],
          vnc: {
            enabled: 0,
            port: 0
          },
          network_boot: 0
      }

      content.each_with_index do |item, idx|
        next if idx == 0

        if item.is_a?(Array)
          case item[0]
            when :id
              guest[:id] = item[1]
            when :ram
              guest[:ram] = item[1].to_i
            when :hvm
              guest[:is_hvm] = item[1].to_i
            when :cpu
              guest[:cpu][:num] = item[1].to_i
            when :cpu_cap
              guest[:cpu][:cap] = item[1].to_i
            when :cpu_weight
              guest[:cpu][:weight] = item[1].to_i
            when :vnc
              guest[:vnc][:enabled] = item[1].to_i
            when :vnc_port
              guest[:vnc][:port] = item[1].to_i
            when :network_boot
              guest[:network_boot] = item[1].to_i
            when :disks
              item.each_with_index do |disk_item, idx|
                next if idx == 0
                guest[:disks] << {number: disk_item[0].to_i, device: disk_item[1]}
              end
            when :ifaces
              item.each_with_index do |iface_item ,idx|
                next if idx == 0
                iface = {}
                iface_item.each do |iface_item2|
                  case iface_item2[0]
                    when :mac
                      iface[:mac] = iface_item2[1]
                    when :bridge
                      iface[:bridge] = iface_item2[1]
                  end
                end

                guest[:ifaces] << iface
              end
          end
        end
      end

      guest
    else
      nil
    end
  end
end

require_relative "verified-port-probe"

listener = TCPServer.new("127.0.0.1", 0)
port = listener.addr[1]
instance = Object.new.extend(Vagrant::Util::IsPortOpen)
raise "Open port was missed" unless Vagrant::Util::IsPortOpen.is_port_open?("127.0.0.1", port)
raise "Instance missed open port" unless instance.is_port_open?("127.0.0.1", port)
listener.close
raise "Closed port was reported open" if Vagrant::Util::IsPortOpen.is_port_open?("127.0.0.1", port)
raise "Instance reported closed port open" if instance.is_port_open?("127.0.0.1", port)
puts "Verified Vagrant port probe checks passed"

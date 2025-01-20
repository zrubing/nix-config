require "socket"

def usage io
  io.puts "Usage: wake-on-lan <mac address>"
  io.puts "       wake-on-lan [--help|-h]"
end

unless ARGV[0]
  STDERR.puts "Error: no MAC address specified"
  usage STDERR
  exit 1
end

if ARGV.size > 1
  STDERR.puts "Error: unrecognized arguments"
  usage STDERR
  exit 1
end

if ARGV[0] == "-h" || ARGV[0] == "--help"
  usage STDOUT
  exit
end

mac_addr = ARGV[0]

mac_addr_parts = mac_addr.split(":")
unless mac_addr_parts.size == 6 && mac_addr_parts.all? { |d| d =~ /^[A-Fa-f0-9]{2}$/ }
  STDERR.puts "Error: invalid MAC address"
  usage STDERR
  exit 1
end

wake = 0xFF.chr * 6 + mac_addr_parts.pack("H*H*H*H*H*H*") * 16

ip = "255.255.255.255"
port = 9

puts "Waking up #{mac_addr} on #{ip}:#{port}"

sock = UDPSocket.open
sock.setsockopt :SOCKET, :BROADCAST, true
sock.connect ip, port
sock.send wake, 0
sock.close

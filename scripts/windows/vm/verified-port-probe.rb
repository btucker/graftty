# Optional, process-local workaround for Vagrant's bundled Ruby returning an
# unconnected Socket.tcp on this macOS host. Check the connection postcondition.
require "socket"
require "vagrant/util/is_port_open"

module GrafttyVerifiedPortProbe
  def is_port_open?(host, port)
    Socket.tcp(host, port, connect_timeout: 0.1) { |socket| socket.getpeername }
    true
  rescue Errno::ETIMEDOUT, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
         Errno::ENETUNREACH, Errno::EACCES, Errno::ENOTCONN,
         Errno::EALREADY, Errno::EINVAL
    false
  end
end

Vagrant::Util::IsPortOpen.prepend(GrafttyVerifiedPortProbe)
Vagrant::Util::IsPortOpen.singleton_class.prepend(GrafttyVerifiedPortProbe)

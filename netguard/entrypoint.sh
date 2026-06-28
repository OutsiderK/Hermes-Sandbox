#!/bin/sh
set -eu

HERMES_UID="${HERMES_UID:-10000}"
PROXY_UID="${PROXY_UID:-10001}"
MIHOMO_UID="${MIHOMO_UID:-10002}"
HERMES_LOOPBACK_TCP_PORTS="${HERMES_LOOPBACK_TCP_PORTS:-3128,9119}"
MIHOMO_TCP_PORTS="${MIHOMO_TCP_PORTS:-80,443,8443,2053,2083,2087,2096}"
PROXY_PORT="${PROXY_PORT:-3128}"

if [ "$(id -u)" -ne 0 ]; then
  echo "FATAL: netguard needs root only to install its namespace firewall." >&2
  exit 70
fi

# Start from a deterministic OUTPUT policy. This network namespace is shared
# with Hermes, so owner-based rules prevent UID 10000 from bypassing the proxy.
iptables -w -F OUTPUT
iptables -w -P OUTPUT DROP

# Responses and local namespace traffic required by the Dashboard/Gateway.
iptables -w -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Do not let Hermes use Docker DNS directly; public names must be resolved by
# tinyproxy. Hermes only gets audited loopback ports, avoiding access to sidecar
# admin/control ports in the shared network namespace.
iptables -w -A OUTPUT -m owner --uid-owner "$HERMES_UID" -d 127.0.0.11/32 -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable
iptables -w -A OUTPUT -m owner --uid-owner "$HERMES_UID" -d 127.0.0.11/32 -p tcp --dport 53 -j REJECT --reject-with icmp-port-unreachable
iptables -w -A OUTPUT -m owner --uid-owner "$HERMES_UID" -o lo -p tcp -m multiport --dports "$HERMES_LOOPBACK_TCP_PORTS" -j ACCEPT
iptables -w -A OUTPUT -m owner --uid-owner "$HERMES_UID" -j REJECT --reject-with icmp-port-unreachable

# Docker's embedded DNS is hosted at 127.0.0.11 inside the shared namespace.
# Some sidecar sockets are not reliably classified by owner match during early
# bootstrap, so allow only DNS here and keep real egress constrained below.
iptables -w -A OUTPUT -d 127.0.0.11/32 -p udp --dport 53 -j ACCEPT
iptables -w -A OUTPUT -d 127.0.0.11/32 -p tcp --dport 53 -j ACCEPT

# tinyproxy may only forward to the local mihomo HTTP proxy. It does not get
# direct DNS or Internet access.
iptables -w -A OUTPUT -m owner --uid-owner "$PROXY_UID" -o lo -p tcp --dport 7890 -j ACCEPT
iptables -w -A OUTPUT -m owner --uid-owner "$PROXY_UID" -j REJECT --reject-with icmp-port-unreachable

# mihomo resolves names and makes the final public TCP connection. It is still
# forbidden from reaching loopback, host, LAN, link-local, multicast and other
# reserved ranges. This guards against bad rules, DNS poisoning and malicious
# subscriptions that try to route Hermes toward protected networks.
iptables -w -A OUTPUT -m owner --uid-owner "$MIHOMO_UID" -d 127.0.0.11/32 -p udp --dport 53 -j ACCEPT
iptables -w -A OUTPUT -m owner --uid-owner "$MIHOMO_UID" -d 127.0.0.11/32 -p tcp --dport 53 -j ACCEPT
for cidr in \
  0.0.0.0/8 \
  10.0.0.0/8 \
  100.64.0.0/10 \
  127.0.0.0/8 \
  169.254.0.0/16 \
  172.16.0.0/12 \
  192.0.0.0/24 \
  192.0.2.0/24 \
  192.88.99.0/24 \
  192.168.0.0/16 \
  198.18.0.0/15 \
  198.51.100.0/24 \
  203.0.113.0/24 \
  224.0.0.0/4 \
  240.0.0.0/4; do
  iptables -w -A OUTPUT -m owner --uid-owner "$MIHOMO_UID" -d "$cidr" -j REJECT --reject-with icmp-port-unreachable
done

# mihomo may reach public web/proxy ports only. Add ports in .env if your
# subscription uses a less common TCP port.
iptables -w -A OUTPUT -m owner --uid-owner "$MIHOMO_UID" -p tcp -m multiport --dports "$MIHOMO_TCP_PORTS" -j ACCEPT
iptables -w -A OUTPUT -m owner --uid-owner "$MIHOMO_UID" -j REJECT --reject-with icmp-port-unreachable

# No other UID, including the short-lived root bootstrap, gets outbound access.
iptables -w -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

# Assert the most important policy before dropping into tinyproxy.
iptables -w -C OUTPUT -m owner --uid-owner "$HERMES_UID" -j REJECT --reject-with icmp-port-unreachable
iptables -w -C OUTPUT -m owner --uid-owner "$HERMES_UID" -o lo -p tcp -m multiport --dports "$HERMES_LOOPBACK_TCP_PORTS" -j ACCEPT
iptables -w -C OUTPUT -d 127.0.0.11/32 -p udp --dport 53 -j ACCEPT
iptables -w -C OUTPUT -d 127.0.0.11/32 -p tcp --dport 53 -j ACCEPT
iptables -w -C OUTPUT -m owner --uid-owner "$PROXY_UID" -o lo -p tcp --dport 7890 -j ACCEPT
iptables -w -C OUTPUT -m owner --uid-owner "$MIHOMO_UID" -p tcp -m multiport --dports "$MIHOMO_TCP_PORTS" -j ACCEPT

exec setpriv --reuid=10001 --regid=10001 --clear-groups --no-new-privs --inh-caps=-all --ambient-caps=-all --bounding-set=-all tinyproxy -d -c /etc/tinyproxy/secure.conf

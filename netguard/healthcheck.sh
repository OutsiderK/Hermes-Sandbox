#!/bin/sh
set -eu
HERMES_UID="${HERMES_UID:-10000}"
PROXY_UID="${PROXY_UID:-10001}"
MIHOMO_UID="${MIHOMO_UID:-10002}"
HERMES_LOOPBACK_TCP_PORTS="${HERMES_LOOPBACK_TCP_PORTS:-3128,9119}"
MIHOMO_TCP_PORTS="${MIHOMO_TCP_PORTS:-80,443,8443,2053,2083,2087,2096}"
pid="$(pidof tinyproxy | awk '{print $1}')"
[ -n "$pid" ]
uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status")"
[ "$uid" = "$PROXY_UID" ]
iptables -w -C OUTPUT -m owner --uid-owner "$HERMES_UID" -j REJECT --reject-with icmp-port-unreachable
iptables -w -C OUTPUT -m owner --uid-owner "$HERMES_UID" -o lo -p tcp -m multiport --dports "$HERMES_LOOPBACK_TCP_PORTS" -j ACCEPT
iptables -w -C OUTPUT -d 127.0.0.11/32 -p udp --dport 53 -j ACCEPT
iptables -w -C OUTPUT -d 127.0.0.11/32 -p tcp --dport 53 -j ACCEPT
iptables -w -C OUTPUT -m owner --uid-owner "$PROXY_UID" -o lo -p tcp --dport 7890 -j ACCEPT
iptables -w -C OUTPUT -m owner --uid-owner "$MIHOMO_UID" -p tcp -m multiport --dports "$MIHOMO_TCP_PORTS" -j ACCEPT
iptables -w -C OUTPUT -m owner --uid-owner "$MIHOMO_UID" -d 169.254.0.0/16 -j REJECT --reject-with icmp-port-unreachable

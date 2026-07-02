#!/bin/sh
set -e

DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}')
GW_IP=$(ip route show default | awk '/default/ {print $3}')
PROXY_IP=${PROXY_IP:-$GW_IP}

echo "[INFO] Using Interface: $DEFAULT_IF"
echo "[INFO] Gateway IP: $GW_IP"
echo "[INFO] Target Proxy: socks5://$PROXY_IP:$PROXY_PORT"

# --- 1. Policy Routing Setup ---
echo "[INFO] Setting up iptables and iproute2..."
mkdir -p /etc/iproute2
if ! grep -q "$TABLE_ID inbound_table" /etc/iproute2/rt_tables 2>/dev/null; then
  echo "$TABLE_ID inbound_table" >> /etc/iproute2/rt_tables
fi

ip route add default via $GW_IP table $TABLE_ID

iptables -t mangle -A PREROUTING -i $DEFAULT_IF -m conntrack --ctstate NEW -j CONNMARK --set-mark $MARK_ID
iptables -t mangle -A OUTPUT -m connmark --mark $MARK_ID -j CONNMARK --restore-mark
ip rule add fwmark $MARK_ID table $TABLE_ID

# --- 2. The Watchdog ---
(
  echo "[INFO] Watchdog started on interface $DEFAULT_IF..."
  while true; do
    if ! ip link show $DEFAULT_IF > /dev/null 2>&1; then
      echo "[ERROR] Network interface $DEFAULT_IF lost! Crashing sidecar..."
      kill -15 1
      sleep 2
      kill -9 1
    fi
    sleep 5
  done
) &

# --- 3. Start the Tunnel ---
echo "[INFO] Starting Gost v3 Transparent Tunnel..."
exec gost -L "tun://?net=${TUN_IP}&route=0.0.0.0/0" -F "socks5://${PROXY_IP}:${PROXY_PORT}"

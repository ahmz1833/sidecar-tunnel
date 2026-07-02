#!/bin/sh
set -e

# --- discover network context ---
DEFAULT_IF=$(ip route show default | awk '/default/ {print $5; exit}')
GW_IP=$(ip route show default | awk '/default/ {print $3; exit}')
PROXY_IP=${PROXY_IP:-$GW_IP}
: "${PROXY_PORT:?PROXY_PORT env var is required}"

MARK_ID=${MARK_ID:-100}
TABLE_ID=${TABLE_ID:-200}
RULE_PREF_INBOUND=${RULE_PREF_INBOUND:-50}

EXCLUDE_CIDRS=${EXCLUDE_CIDRS:-"10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"}

echo "[INFO] iface=$DEFAULT_IF gw=$GW_IP proxy=socks5://$PROXY_IP:$PROXY_PORT"

# --- reject reserved kernel table IDs ---
if [ "$TABLE_ID" -eq 0 ] || [ "$TABLE_ID" -ge 253 ]; then
  echo "[FATAL] table id $TABLE_ID is reserved by the kernel. pick 1-252." >&2
  exit 1
fi

# --- rt_tables ---
mkdir -p /etc/iproute2
grep -q "^${TABLE_ID}[[:space:]]inbound_table$" /etc/iproute2/rt_tables 2>/dev/null \
  || echo "$TABLE_ID inbound_table" >> /etc/iproute2/rt_tables

# --- inbound_table: return path for externally-initiated connections ---
ip route replace default via "$GW_IP" dev "$DEFAULT_IF" table "$TABLE_ID"

# --- keep private ranges off the tunnel ---
for cidr in $EXCLUDE_CIDRS; do
  ip route replace "$cidr" via "$GW_IP" dev "$DEFAULT_IF"
done

# --- mark inbound NEW connections, restore mark on their reply packets ---
iptables -t mangle -F
iptables -t mangle -A PREROUTING -i "$DEFAULT_IF" -m addrtype ! --src-type LOCAL -m conntrack --ctstate NEW -j CONNMARK --set-mark "$MARK_ID"
iptables -t mangle -A OUTPUT -m connmark --mark "$MARK_ID" -j CONNMARK --restore-mark

# --- ip rule: setup return path for marked packets ---
ip rule del pref "$RULE_PREF_INBOUND"  2>/dev/null || true
ip rule add pref "$RULE_PREF_INBOUND"  fwmark "$MARK_ID" lookup "$TABLE_ID"

echo "[INFO] ip rule table:"
ip rule list

# --- setup tun interface for tun2socks ---
echo "[INFO] configuring tun0 interface..."
ip link delete tun0 2>/dev/null || true
ip tuntap add mode tun dev tun0
ip addr add "${TUN_IP}" dev tun0
ip link set dev tun0 up

# --- start tun2socks ---
echo "[INFO] starting tun2socks..."
tun2socks -device tun0 -proxy "socks5://${PROXY_IP}:${PROXY_PORT}" -loglevel debug &
PROXY_PID=$!

# --- watchdog ---
while true; do
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "[ERROR] tun2socks process died, exiting"
    exit 1
  fi
  if ! ip link show "$DEFAULT_IF" > /dev/null 2>&1; then
    echo "[ERROR] $DEFAULT_IF lost, exiting"
    exit 1
  fi
  if ip link show tun0 > /dev/null 2>&1; then
    ip route replace 0.0.0.0/1   dev tun0 2>/dev/null || true
    ip route replace 128.0.0.0/1 dev tun0 2>/dev/null || true
  fi
  sleep 5
done

#!/bin/sh
set -e

# --- discover network context ---
DEFAULT_IF=$(ip route show default | awk '/default/ {print $5; exit}')
GW_IP=$(ip route show default | awk '/default/ {print $3; exit}')
PROXY_IP=${PROXY_IP:-$GW_IP}
: "${PROXY_PORT:?PROXY_PORT env var is required}"

MARK_ID=${MARK_ID:-100}
TABLE_ID=${TABLE_ID:-200}
RULE_PREF_INBOUND=${RULE_PREF_INBOUND:-50}   # must be lower than main (32766)

GOST_MARK=${GOST_MARK:-255}
GOST_TABLE_ID=${GOST_TABLE_ID:-220}          # never 0/253/254/255, kernel-reserved
RULE_PREF_GOST=${RULE_PREF_GOST:-10}         # must be lower than RULE_PREF_INBOUND

echo "[INFO] iface=$DEFAULT_IF gw=$GW_IP proxy=socks5://$PROXY_IP:$PROXY_PORT"

# --- reject reserved kernel table IDs (unspec/default/main/local) ---
for t in "$TABLE_ID" "$GOST_TABLE_ID"; do
  case "$t" in
    0|253|254|255)
      echo "[FATAL] table id $t is reserved by the kernel. pick 1-252." >&2
      exit 1
      ;;
  esac
done

# --- rp_filter: loosen to avoid drops from multi-table policy routing ---
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
  ( echo 0 > "$f" ) 2>/dev/null || true
done

# --- rt_tables ---
mkdir -p /etc/iproute2
grep -q "^${TABLE_ID}[[:space:]]inbound_table$" /etc/iproute2/rt_tables 2>/dev/null \
  || echo "$TABLE_ID inbound_table" >> /etc/iproute2/rt_tables
grep -q "^${GOST_TABLE_ID}[[:space:]]gost_table$" /etc/iproute2/rt_tables 2>/dev/null \
  || echo "$GOST_TABLE_ID gost_table" >> /etc/iproute2/rt_tables

# --- inbound_table: return path for externally-initiated connections ---
ip route replace default via "$GW_IP" dev "$DEFAULT_IF" table "$TABLE_ID"

# --- gost_table: gost's own egress to the SOCKS5 server, bypasses tun0 ---
SUBNET=$(ip route show dev "$DEFAULT_IF" scope link | awk '!/default/ {print $1; exit}')
[ -n "$SUBNET" ] && ip route replace "$SUBNET" dev "$DEFAULT_IF" table "$GOST_TABLE_ID"
ip route replace default via "$GW_IP" dev "$DEFAULT_IF" table "$GOST_TABLE_ID"

# --- mark inbound NEW connections, restore mark on their reply packets ---
iptables -t mangle -F
iptables -t mangle -A PREROUTING -i "$DEFAULT_IF" -m conntrack --ctstate NEW -j CONNMARK --set-mark "$MARK_ID"
iptables -t mangle -A OUTPUT -m connmark --mark "$MARK_ID" -j CONNMARK --restore-mark

# --- ip rule: explicit priority is required, do not rely on the default ---
ip rule del pref "$RULE_PREF_GOST"     2>/dev/null || true
ip rule del pref "$RULE_PREF_INBOUND"  2>/dev/null || true
ip rule add pref "$RULE_PREF_GOST"    fwmark "$GOST_MARK" lookup "$GOST_TABLE_ID"
ip rule add pref "$RULE_PREF_INBOUND" fwmark "$MARK_ID"   lookup "$TABLE_ID"

echo "[INFO] ip rule table:"
ip rule list

# --- watchdog: keep tun0 default routes in place, crash sidecar on iface loss ---
(
  echo "[INFO] watchdog started"
  while true; do
    if ! ip link show "$DEFAULT_IF" > /dev/null 2>&1; then
      echo "[ERROR] $DEFAULT_IF lost, crashing sidecar"
      kill -TERM 1; sleep 2; kill -KILL 1
    fi
    if ip link show tun0 > /dev/null 2>&1; then
      ip route replace 0.0.0.0/1   dev tun0 2>/dev/null || true
      ip route replace 128.0.0.0/1 dev tun0 2>/dev/null || true
    fi
    sleep 5
  done
) &

# --- start gost tun tunnel ---
echo "[INFO] starting gost tun tunnel..."
exec gost -L "tun://?net=${TUN_IP}" -F "socks5://${PROXY_IP}:${PROXY_PORT}?so_mark=${GOST_MARK}"

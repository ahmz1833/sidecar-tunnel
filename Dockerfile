FROM xjasonlyu/tun2socks:v2.5.2 AS tun2socks-bin
FROM alpine:latest

ENV PROXY_PORT=2080
ENV TUN_IP="169.254.254.1/30"

# inbound-preservation path (fwmark -> table)
ENV MARK_ID=100
ENV TABLE_ID=200
ENV RULE_PREF_INBOUND=50

# tun2socks's own egress to the SOCKS5 server (fwmark -> table), must bypass tun0
ENV PROXY_MARK=255
ENV PROXY_TABLE_ID=220
ENV RULE_PREF_PROXY=10
# PROXY_TABLE_ID/TABLE_ID must stay in 1-252; 0/253/254/255 are kernel-reserved
# RULE_PREF_PROXY must stay lower than RULE_PREF_INBOUND, both lower than 32766

# private ranges routed via the normal gateway instead of the proxy
ENV EXCLUDE_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"

# iproute2/iptables: required for policy routing
# tcpdump: for debugging traffic on eth0/tun0 without shipping a separate debug image
# bind-tools: dig/nslookup, useful for verifying DNS actually goes through the proxy
RUN apk add --no-cache \
    iproute2 \
    iptables \
    tcpdump \
    bind-tools \
    curl \
  && rm -rf /var/cache/apk/*

COPY --from=tun2socks-bin /tun2socks /usr/local/bin/tun2socks
RUN chmod +x /usr/local/bin/tun2socks

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

FROM gogost/gost:3.2

ENV PROXY_PORT=2080
ENV TUN_IP="169.254.254.1/30"
ENV MARK_ID=100
ENV TABLE_ID=200

RUN apk add --no-cache iptables iproute2

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

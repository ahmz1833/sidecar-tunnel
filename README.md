# sidecar-tunnel

A transparent proxy sidecar for Docker containers. It routes all outbound TCP and UDP traffic through a SOCKS5 proxy using `tun2socks`, while keeping your exposed inbound ports working perfectly.

## How it works

1. Creates a `tun0` interface and uses longest-prefix match routing (`0.0.0.0/1`, `128.0.0.0/1`) to intercept outbound traffic.
2. Forwards intercepted traffic to your SOCKS5 proxy.
3. Uses `iptables` and policy routing to mark externally-initiated inbound connections, ensuring their replies bypass the tunnel and return via the correct gateway.

## Usage Examples

The sidecar works by attaching itself to the target application's network namespace. You can do this either in the same `docker-compose` file, or attach it to a completely independent, already-running container.

### Scenario A: Independent Deployments (Attach to an existing container)

This is the most flexible approach. Your main application runs independently, and you attach the sidecar to it using `network_mode: "container:<container_name>"`. They do not need to share a compose file.

```yaml
# sidecar-compose.yml
services:
  sidecar-proxy:
    image: ghcr.io/ahmz1833/sidecar-tunnel:latest
    container_name: sidecar-proxy
    # Attach directly to an already running container by its name
    network_mode: "container:my-production-app"
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    environment:
      - PROXY_PORT=10808
```

### Scenario B: Single Compose File

If you prefer to deploy them together, use `network_mode: "service:<service_name>"`. The main app keeps its custom networks and port bindings untouched.

```yaml
# docker-compose.yml
services:
  main-app:
    image: your-app-image
    container_name: my-production-app
    ports:
      - "8080:80"
    networks:
      - custom-bridge-network

  sidecar-proxy:
    image: ghcr.io/ahmz1833/sidecar-tunnel:latest
    network_mode: "service:main-app"
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    environment:
      - PROXY_PORT=10808
    depends_on:
      - main-app

networks:
  custom-bridge-network:
    driver: bridge
```

## Environment Variables

| **Variable**    | **Default**        | **Description**                       |
| --------------- | ------------------ | ------------------------------------- |
| `PROXY_PORT`    | `2080`             | The SOCKS5 proxy port.                |
| `PROXY_IP`      | Default Gateway    | The SOCKS5 proxy IP.                  |
| `TUN_IP`        | `169.254.254.1/30` | Internal IP for the `tun0` interface. |
| `EXCLUDE_CIDRS` | Private ranges     | Subnets that must bypass the proxy.   |

## Host Firewall Configuration (Crucial for UDP)

If your SOCKS5 proxy (e.g., sing-box, xray) is running on the host machine, the host's firewall must be configured to accept traffic from Docker containers.

SOCKS5 uses a fixed port for TCP connections, but inherently requires **ephemeral (random) ports** to relay UDP traffic (like DNS).

To make this automation-friendly without hardcoding dynamic Docker IPs, you can trust traffic coming from Docker's virtual interfaces (`br-+` for docker-compose networks and `docker0` for default bridge). Apply these rules to your host machine:

```bash
# 1. Allow TCP control connection (Replace 10808 with your proxy port)
sudo iptables -A INPUT -i br-+ -p tcp --dport 10808 -j ACCEPT
sudo iptables -A INPUT -i docker0 -p tcp --dport 10808 -j ACCEPT

# 2. Allow UDP Associate (Linux ephemeral ports range)
sudo iptables -A INPUT -i br-+ -p udp --dport 32768:60999 -j ACCEPT
sudo iptables -A INPUT -i docker0 -p udp --dport 32768:60999 -j ACCEPT
```

*(Note: Limiting the rules to Docker interfaces ensures your host remains secure from external internet traffic).*
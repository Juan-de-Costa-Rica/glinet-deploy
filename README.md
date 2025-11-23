# GL.iNet Brume 2 Exit Node Deployment

Automated setup scripts for deploying GL.iNet Brume 2 routers as Tailscale exit nodes with backup SSH tunnel access via Oracle Cloud.

## Quick Start

### Deploy to a New Router

```bash
# From your local machine (router at default IP)
./deploy.sh 192.168.8.1 chicago 211

# Or via Tailscale (if already set up)
./deploy.sh myrouter-210
```

### What Gets Configured

| Component | Description |
|-----------|-------------|
| **Tailscale** | Exit node with auto-reconnect watchdog |
| **SSH Tunnel** | Reverse tunnel to Oracle Cloud (backup access) |
| **NextDNS** | Encrypted DNS with ad-blocking (optional) |
| **Network** | Hostname and LAN IP based on location ID |

## Architecture

```
┌─────────────────┐     Tailscale      ┌─────────────────┐
│   Your Device   │◄──────────────────►│   Brume 2       │
│   (anywhere)    │                    │   (exit node)   │
└─────────────────┘                    └────────┬────────┘
        │                                       │
        │  Backup: SSH Tunnel                   │
        │                                       ▼
        │                              ┌─────────────────┐
        └─────────────────────────────►│  Oracle Cloud   │
           ssh -J opc@oracle ...       │  (port 22xx)    │
                                       └─────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Run from local machine to deploy to router |
| `setup.sh` | Main setup script (runs ON the router) |
| `config/defaults.conf` | Default configuration values |
| `docs/oracle-setup.md` | Oracle Cloud infrastructure setup guide |

## Configuration

Edit `config/defaults.conf` before deploying:

```bash
# Oracle Cloud (backup tunnel server)
VPS_IP="YOUR-VPS-IP"
VPS_USER="opc"
VPS_SSH_PORT="22"

# Tailscale auth key (generate at https://login.tailscale.com/admin/settings/keys)
TAILSCALE_AUTHKEY=""   # Leave empty to prompt during setup

# NextDNS profile ID
NEXTDNS_ID="abc123"
```

## Location ID Scheme

The location ID determines IP addressing:

| Location | ID | Gateway IP | Tunnel Port |
|----------|-----|------------|-------------|
| newyork | 210 | 192.168.210.1 | 2210 |
| chicago | 211 | 192.168.211.1 | 2211 |
| denver | 212 | 192.168.212.1 | 2212 |

**Note:** Valid IDs are 100-254 (ensures tunnel ports avoid well-known ports)

## Usage Examples

### Interactive Deployment
```bash
./deploy.sh 192.168.8.1
# Follow prompts for location name, ID, etc.
```

### Automated Deployment
```bash
./deploy.sh 192.168.8.1 denver 212
# No prompts - runs with provided values
```

### Access After Deployment

```bash
# Via Tailscale (primary)
ssh root@denver-212

# Via local network
ssh root@192.168.212.1

# Via Oracle tunnel (backup - if Tailscale is down)
ssh -J opc@YOUR-VPS-IP root@localhost -p 2212
```

### Use as Exit Node

```bash
# Route all traffic through the router
tailscale up --exit-node=denver-212

# Stop using exit node
tailscale up --exit-node=
```

## Deployed Router Scripts

After setup, these scripts run on the router:

| Script | Location | Purpose |
|--------|----------|---------|
| `keep-tailscale-alive.sh` | `/usr/bin/` | Watchdog (cron every 5 min) |
| `reverse-tunnel-XXX.sh` | `/usr/bin/` | SSH tunnel (auto-start on boot) |

## Troubleshooting

### Tailscale Not Connecting
```bash
ssh root@<router>
tailscale status
/etc/init.d/tailscale restart
```

### Tunnel Not Working
```bash
# Check tunnel process on router
ssh root@<router> "ps | grep reverse-tunnel"

# Check port on Oracle
ssh oracle "ss -tlnp | grep 22XX"

# Restart tunnel
ssh root@<router> "killall reverse-tunnel-XXX.sh; /usr/bin/reverse-tunnel-XXX.sh &"
```

### Reset to Factory
If something goes wrong, you can always factory reset the router via the hardware button and start fresh.

## Current Deployments

Track your deployments here:

| Router | Location | Tailscale IP | Tunnel Port | Status |
|--------|----------|--------------|-------------|--------|
| example-210 | Example City | 100.x.x.x | 2210 | - |

## Version History

- **1.0** (2025-11-22): Initial consolidated version
  - Combined best features from v4.1, v4.2, v5.0
  - Updated to Oracle Cloud settings
  - Added local deployment script

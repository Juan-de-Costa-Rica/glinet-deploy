# GL.iNet Brume 2 API Reference

Complete reference for RPC API and UCI configuration on GL-MT2500 (firmware 4.7.4).

## Quick Reference

### RPC vs UCI Decision Matrix

| Setting | RPC Available? | Use Method |
|---------|---------------|------------|
| **Tailscale enable/disable** | Yes | `tailscale.set_config` |
| **DNS/NextDNS** | Yes | `dns.set_config` |
| **Hostname** | No | UCI: `system.@system[0].hostname` |
| **LAN IP** | No | UCI: `network.lan.ipaddr` |
| **WireGuard server** | Yes | `wg-server.set_config` |
| **OpenVPN server** | Yes | `ovpn-server.set_config` |
| **Firewall rules** | Partial | RPC: `firewall.add_rule` |
| **DHCP settings** | No | UCI: `dhcp.lan.*` |
| **SSH port** | No | UCI: `dropbear.@dropbear[0].Port` |

---

## RPC API

### Making RPC Calls

```bash
# Basic structure (no auth needed from localhost)
curl -H 'glinet: 1' -s http://127.0.0.1/rpc -d '{
  "jsonrpc": "2.0",
  "method": "call",
  "params": ["", "<module>", "<method>", {<params>}],
  "id": 1
}'
```

### Available Modules

All modules are located in `/usr/lib/oui-httpd/rpc/`.

---

## Core System Modules

### system

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_info` | `{}` | Complete system info (model, firmware, features) |
| `get_status` | `{}` | Network status, services, memory, CPU |
| `reboot` | `{}` | Reboot the router |

**Example: get_info response**
```json
{
  "model": "mt2500",
  "firmware_version": "4.7.4",
  "board_info": {
    "hostname": "myrouter-210",
    "kernel_version": "5.4.211",
    "openwrt_version": "OpenWrt 21.02-SNAPSHOT"
  },
  "software_feature": {
    "vpn": true, "tor": true, "adguard": true, "nas": true
  }
}
```

### upgrade

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Get upgrade settings |
| `set_config` | `{"rc_upgrade":bool,"prompt":bool}` | Configure upgrade behavior |
| `reboot` | `{}` | Reboot router |

---

## Network Services

### tailscale

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Returns enabled, lan_ip, lan_enabled, wan_enabled |
| `set_config` | `{"enabled":bool}` | Enable/disable Tailscale |
| `get_status` | `{}` | Returns login_name, status, address_v4 |

**Status codes:** 0=disabled, 1=connecting, 2=needs auth, 3=connected

**Example: Enable Tailscale**
```bash
curl -H 'glinet: 1' -s http://127.0.0.1/rpc -d '{
  "jsonrpc":"2.0",
  "method":"call",
  "params":["","tailscale","set_config",{"enabled":true}],
  "id":1
}'
```

### zerotier

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Returns enabled, wan_enabled, lan_enabled |
| `set_config` | `{"enabled":bool}` | Enable/disable ZeroTier |
| `get_status` | `{}` | Connection status |

### dns

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Current DNS settings |
| `set_config` | See below | Configure DNS |
| `get_info` | `{}` | Available DNS protocols and servers |

**DNS Configuration Parameters:**
```json
{
  "mode": "secure",           // "auto", "manual", "secure"
  "proto": "DoT",             // "DoT", "DoH", "DNSCrypt", "oDoH"
  "dot_provider": "1",        // Provider ID (1=NextDNS)
  "nextdns_id": "abc123",     // NextDNS profile ID
  "force_dns": true,          // Force clients to use router DNS
  "override_vpn": true,       // Override VPN DNS
  "rebind_protection": false
}
```

### ddns

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | DDNS settings |
| `set_config` | `{"enable_ddns":bool}` | Enable/disable DDNS |
| `get_status` | `{}` | DDNS status |

---

## VPN Modules

### wg-client (WireGuard Client)

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_status` | `{}` | Connection status, rx/tx bytes |
| `get_all_config_list` | `{}` | List of saved configs |
| `get_group_list` | `{}` | VPN provider groups (AzireVPN, etc.) |

### wg-server (WireGuard Server)

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Server configuration |
| `set_config` | See below | Configure server |
| `get_status` | `{}` | Server status, connected peers |

**WireGuard Server Config:**
```json
{
  "port": 51820,
  "address_v4": "10.0.0.1/24",
  "address_v6": "fd00:db8:0:abc::1/64",
  "local_access": false,
  "ipv6_enable": false
}
```

### ovpn-client (OpenVPN Client)

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_status` | `{}` | Connection status |
| `get_all_config_list` | `{}` | List of saved configs |
| `get_group_list` | `{}` | VPN provider groups (NordVPN, etc.) |

### ovpn-server (OpenVPN Server)

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Server configuration |
| `set_config` | See below | Configure server |
| `get_status` | `{}` | Server status |

### tor

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Tor settings |
| `set_config` | `{"enable":bool}` | Enable/disable Tor |
| `get_status` | `{}` | Tor status |

### vpn-policy

| Method | Parameters | Description |
|--------|------------|-------------|
| (needs more testing) | | VPN routing policies |

---

## Security & Access

### firewall

| Method | Parameters | Description |
|--------|------------|-------------|
| `add_rule` | (params needed) | Add firewall rule |
| `add_port_forward` | (params needed) | Add port forward |
| `get_dmz` | `{}` | Get DMZ settings |

**Note:** Most firewall config requires UCI.

### local-access

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | HTTP/HTTPS/SSH port settings |
| `set_config` | See below | Configure access ports |

**Local Access Config:**
```json
{
  "http_port": 80,
  "https_port": 443,
  "ssh_port": 22,
  "luci_http_port": 8080,
  "luci_https_port": 8443,
  "redirect_https": false,
  "session_timeout": 300
}
```

### parental-control

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Parental control settings |
| `set_config` | (params needed) | Configure controls |
| `get_status` | `{}` | Status |

### black_white_list

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Returns mode ("black" or "white") |
| `set_config` | `{"mode":"black"}` | Set list mode |

### acl

Access control lists (needs more testing).

---

## Clients & Monitoring

### clients

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_list` | `{}` | All connected/known clients |
| `get_status` | `{}` | Client statistics |

**Client Info Includes:**
- MAC address, IP, IPv6, hostname
- Online status, interface (cable/wireless)
- TX/RX bytes, bandwidth history
- Blocked status

---

## Hardware & System

### led

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | LED settings |
| `set_config` | `{"led_enable":bool}` | Enable/disable LEDs |

### qos

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | QoS settings |
| `set_config` | `{"enable":bool,"mode":"0"}` | Configure QoS |

### igmp

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | IGMP snooping settings |
| `set_config` | `{"enable":bool,"version":3}` | Configure IGMP |

### cable

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | WAN protocol (dhcp/static/pppoe) |
| `set_config` | See UCI instead | Configure WAN |
| `get_status` | `{}` | WAN connection status |

### tethering

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | USB tethering settings |
| `get_status` | `{}` | Tethering status |

---

## Cloud & Remote

### cloud

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | GoodCloud settings |
| `set_config` | `{"cloud_enable":bool}` | Enable/disable cloud |

### rtty

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Remote terminal settings |
| `set_config` | `{"web_enabled":bool,"ssh_enabled":bool}` | Configure rtty |

### s2s

Site-to-site VPN (get_status only).

---

## Additional Modules

### adguardhome

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | AdGuard Home settings |
| `set_config` | `{"enabled":bool,"dns_enabled":bool}` | Configure AdGuard |

### mptun

Multi-path tunnel (get_config, get_status, set_config).

### plugins

| Method | Parameters | Description |
|--------|------------|-------------|
| `get_config` | `{}` | Plugin settings |
| `get_list` | `{}` | Installed plugins |

### kmwan

Multi-WAN settings (failover, load balancing).

### edgerouter

Edge router mode settings.

### sms-forward

SMS forwarding (for models with cellular).

### modem

Cellular modem settings (for models with LTE).

### nas-web

NAS/file sharing status.

---

## UCI Configuration

For settings not available via RPC.

### System

```bash
# Hostname
uci set system.@system[0].hostname="router-name"
uci commit system

# Timezone
uci set system.@system[0].timezone="CST6CDT,M3.2.0,M11.1.0"
uci set system.@system[0].zonename="America/Chicago"
uci commit system
```

### Network

```bash
# LAN IP
uci set network.lan.ipaddr="192.168.210.1"
uci set network.lan.netmask="255.255.255.0"
uci commit network

# WAN (DHCP)
uci set network.wan.proto="dhcp"
uci commit network

# WAN (Static)
uci set network.wan.proto="static"
uci set network.wan.ipaddr="x.x.x.x"
uci set network.wan.netmask="255.255.255.0"
uci set network.wan.gateway="x.x.x.1"
uci commit network
```

### DHCP

```bash
# DHCP range
uci set dhcp.lan.start="100"
uci set dhcp.lan.limit="150"
uci set dhcp.lan.leasetime="12h"
uci commit dhcp

# Static lease
uci add dhcp host
uci set dhcp.@host[-1].mac="AA:BB:CC:DD:EE:FF"
uci set dhcp.@host[-1].ip="192.168.210.50"
uci set dhcp.@host[-1].name="mydevice"
uci commit dhcp
```

### SSH (Dropbear)

```bash
# Change SSH port
uci set dropbear.@dropbear[0].Port="2222"
uci commit dropbear
/etc/init.d/dropbear restart
```

### Firewall

```bash
# Allow incoming port
uci add firewall rule
uci set firewall.@rule[-1].name="Allow-Custom"
uci set firewall.@rule[-1].src="wan"
uci set firewall.@rule[-1].dest_port="8080"
uci set firewall.@rule[-1].proto="tcp"
uci set firewall.@rule[-1].target="ACCEPT"
uci commit firewall
/etc/init.d/firewall reload

# Port forward
uci add firewall redirect
uci set firewall.@redirect[-1].name="Forward-HTTP"
uci set firewall.@redirect[-1].src="wan"
uci set firewall.@redirect[-1].src_dport="8080"
uci set firewall.@redirect[-1].dest="lan"
uci set firewall.@redirect[-1].dest_ip="192.168.210.50"
uci set firewall.@redirect[-1].dest_port="80"
uci set firewall.@redirect[-1].proto="tcp"
uci commit firewall
/etc/init.d/firewall reload
```

### Tailscale (UCI)

```bash
# View current
uci show tailscale

# Settings stored in:
# tailscale.settings.enabled
# tailscale.settings.port
# tailscale.settings.lan_enabled
# tailscale.settings.wan_enabled
```

### DNS (UCI)

```bash
# View GL.iNet DNS settings
uci show gl-dns

# Settings stored in:
# gl-dns.@dns[0].mode
# gl-dns.@dns[0].proto
# gl-dns.@dns[0].nextdns_id
# gl-dns.@dns[0].dot_provider
```

---

## UCI Config Files

All configs in `/etc/config/`:

| File | Purpose |
|------|---------|
| `system` | Hostname, timezone, NTP |
| `network` | Interfaces, IPs, routing |
| `dhcp` | DHCP server, DNS settings |
| `firewall` | Firewall rules, zones |
| `dropbear` | SSH daemon settings |
| `tailscale` | Tailscale settings |
| `gl-dns` | GL.iNet DNS settings |
| `wireguard` | WireGuard client configs |
| `wireguard_server` | WireGuard server config |
| `openvpn` | OpenVPN settings |
| `wireless` | WiFi (not on MT2500) |

---

## Error Handling

### RPC Errors

```json
// Method not found
{"id":1,"jsonrpc":"2.0","error":{"message":"Method not found","code":-32601}}

// Invalid params
{"id":1,"jsonrpc":"2.0","error":{"message":"Invalid params","code":-32602}}

// Success
{"id":1,"jsonrpc":"2.0","result":{...}}
```

### UCI Errors

```bash
# Check if setting exists
uci get system.@system[0].hostname || echo "not found"

# Always commit after changes
uci commit <config>

# Restart service if needed
/etc/init.d/<service> restart
```

---

## Best Practices

1. **Use RPC when available** - it syncs with GL.iNet admin panel
2. **Use UCI for OpenWrt core** - hostname, network, firewall
3. **Always commit UCI changes** - `uci commit <config>`
4. **Restart services after UCI changes** - `/etc/init.d/<service> restart`
5. **Verify after changes** - read back to confirm

---

## Firmware Notes

- Tested on: GL-MT2500, firmware 4.7.4
- RPC modules in: `/usr/lib/oui-httpd/rpc/`
- Official API docs were removed in January 2024
- This reference was created via live testing

---

## References

- [GL.iNet Forum](https://forum.gl-inet.com/)
- [python-glinet library](https://github.com/tomtana/python-glinet)
- [OpenWrt UCI documentation](https://openwrt.org/docs/guide-user/base-system/uci)

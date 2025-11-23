# GL.iNet RPC API vs UCI Configuration

## Overview

GL.iNet routers run OpenWrt with a custom GL.iNet layer. Configuration can be done via:
- **UCI** (Unified Configuration Interface) - OpenWrt standard
- **RPC API** - GL.iNet's JSON-RPC API at `http://127.0.0.1/rpc`

## When to Use Which

### Use RPC API For:
- **Tailscale** - `tailscale.set_config`, `tailscale.get_config`
- **DNS/NextDNS** - `dns.set_config`, `dns.get_config`
- **System info** (read-only) - `system.get_info`
- Any GL.iNet-specific feature visible in their admin panel

### Use UCI For:
- **Hostname** - `system.@system[0].hostname`
- **LAN IP** - `network.lan.ipaddr`
- **DHCP settings** - `dhcp.lan.*`
- **Firewall rules** - `firewall.*`
- Any standard OpenWrt configuration

## RPC API Reference

### Making RPC Calls

```bash
curl -H 'glinet: 1' -s -k http://127.0.0.1/rpc -d \
  '{"jsonrpc":"2.0","method":"call","params":["","<module>","<method>",{<params>}],"id":1}'
```

### Available Modules (Tested on GL-MT2500 firmware 4.7.4)

| Module | Method | Parameters | Notes |
|--------|--------|------------|-------|
| `system` | `get_info` | `{}` | Read-only system information |
| `tailscale` | `get_config` | `{}` | Returns enabled, lan_ip, lan_enabled, wan_enabled |
| `tailscale` | `set_config` | `{"enabled":true}` | Enable/disable Tailscale |
| `dns` | `get_config` | `{}` | Returns mode, provider, nextdns_id, etc. |
| `dns` | `set_config` | See below | Configure DNS settings |

### DNS Configuration Example

```bash
curl -H 'glinet: 1' -s -k http://127.0.0.1/rpc -d '{
  "jsonrpc":"2.0",
  "method":"call",
  "params":["","dns","set_config",{
    "mode":"secure",
    "force_dns":true,
    "override_vpn":true,
    "dot_provider":"1",
    "nextdns_id":"abc123",
    "proto":"DoT"
  }],
  "id":1
}'
```

### Methods NOT Available via RPC

These return "Method not found" and require UCI:
- `system.set_hostname`
- `network.get_config` / `set_config`
- `lan.get_config` / `set_config`
- `router.get_config`
- `ui.get_config`
- `netmode.get_config`

## Why Mix Both?

1. **GL.iNet RPC is intentionally limited** - only exposes GL.iNet-specific features
2. **OpenWrt core uses UCI** - hostname, network, firewall are standard OpenWrt
3. **RPC syncs with GL.iNet admin panel** - changes appear in web UI immediately
4. **UCI is the authoritative source** - RPC reads from UCI for system info

## Best Practices

1. **Use RPC when available** - it's the "official" GL.iNet way
2. **Fall back to UCI for core OpenWrt settings** - hostname, network, etc.
3. **Always commit UCI changes** - `uci commit <config>`
4. **Verify after changes** - read back via RPC or UCI to confirm

## Verification Pattern

```bash
# Set hostname via UCI (only way)
uci set system.@system[0].hostname="router-name"
uci commit system

# Verify via RPC (reads from system)
curl -H 'glinet: 1' -s -k http://127.0.0.1/rpc -d \
  '{"jsonrpc":"2.0","method":"call","params":["","system","get_info",{}],"id":1}' \
  | grep -o '"hostname":"[^"]*"'
```

## Error Handling

RPC errors return:
```json
{"id":1,"jsonrpc":"2.0","error":{"message":"Method not found","code":-32601}}
```

Always check for `"result"` in successful responses:
```json
{"id":1,"jsonrpc":"2.0","result":{...}}
```

# Oracle Cloud Reverse SSH Tunnel Setup Guide

## Overview

This guide documents the complete setup of reverse SSH tunnels from GL.iNet Brume2 routers to an Oracle Cloud Free Tier instance, providing backup access when Tailscale is unavailable.

## Architecture

- **Primary Access**: Tailscale direct connection
- **Backup Access**: Reverse SSH tunnel via Oracle Cloud instance
- **Router**: GL.iNet Brume2 (OpenWrt-based)
- **Server**: Oracle Linux 9.6 (Free Tier)

---

## Server Configuration (Oracle Cloud Instance)

### 1. SSH Daemon Configuration

Edit `/etc/ssh/sshd_config` and add/modify:

```bash
sudo vi /etc/ssh/sshd_config
```

Add these lines:

```
GatewayPorts yes
AllowTcpForwarding yes
ClientAliveInterval 30
ClientAliveCountMax 3

# For dropbear SSH keys compatibility
PubkeyAcceptedKeyTypes +ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa
HostKeyAlgorithms +ssh-rsa
```

Restart SSH:

```bash
sudo systemctl restart sshd
sudo systemctl status sshd
```

### 2. Server Firewall Configuration

Oracle Linux uses `firewalld`:

```bash
# Add tunnel ports
sudo firewall-cmd --permanent --add-port=2210/tcp
sudo firewall-cmd --permanent --add-port=2211/tcp  # For additional routers
sudo firewall-cmd --permanent --add-port=2212/tcp  # For additional routers

# Reload firewall
sudo firewall-cmd --reload

# Verify rules
sudo firewall-cmd --list-all
```

### 3. SSH Key Setup

```bash
# Ensure correct permissions
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Add router public keys (get from each router)
echo "ssh-rsa AAAAB3NzaC1yc2E... root@router-name" >> ~/.ssh/authorized_keys
```

---

## Oracle Cloud Security List Configuration

### Adding Ingress Rules via Web Console

1. **Access Oracle Cloud Console**
    
    - Log into https://cloud.oracle.com
    - Navigate to: **Compute** → **Instances**
    - Click on your instance name
2. **Navigate to Security Lists**
    
    - In the instance details, under **Primary VNIC**
    - Click on the **Subnet** link
    - In the subnet details, click **Security Lists**
    - Click on the default security list (usually named similar to "Default Security List for vcn-...")
3. **Add Ingress Rules**
    
    - Click **Add Ingress Rules**
    - Fill in the following for each tunnel port:
    
    ```
    Source Type: CIDR
    Source CIDR: 0.0.0.0/0
    IP Protocol: TCP
    Source Port Range: (leave blank or "All")
    Destination Port Range: 2210
    Description: SSH Reverse Tunnel - Router 1
    ```
    
4. **Repeat for Additional Routers**
    
    - Port 2211 for Router 2
    - Port 2212 for Router 3
    - etc.
5. **Save Changes**
    
    - Click **Add Ingress Rules**
    - Rules take effect immediately

---

## Router Configuration (GL.iNet Brume2)

### 1. Generate SSH Key (if not already done)

```bash
# For Dropbear (most common)
mkdir -p /root/.ssh
dropbearkey -t rsa -f /root/.ssh/id_dropbear -s 2048
dropbearkey -y -f /root/.ssh/id_dropbear | grep "^ssh-rsa" > /root/.ssh/id_dropbear.pub
cat /root/.ssh/id_dropbear.pub
```

### 2. Update Tunnel Script

Edit `/usr/bin/reverse-tunnel.sh`:

```bash
#!/bin/sh
# Maintain reverse SSH tunnel from router to Oracle Cloud VPS

REMOTE_HOST="YOUR-ORACLE-IP"        # Oracle instance IP
REMOTE_USER="opc"                 # Oracle default user
REMOTE_SSH_PORT="22"              # SSH port
TUNNEL_PORT="2210"                # Unique port per router (2210, 2211, 2212...)
LOCAL_PORT="22"                   # Router SSH port

while true; do
    if ! pgrep -f "ssh.*${TUNNEL_PORT}.*${REMOTE_HOST}" > /dev/null; then
        logger "Starting reverse SSH tunnel to ${REMOTE_HOST}"
        
        ssh -p ${REMOTE_SSH_PORT} \
            -N \
            -f \
            -K 60 \
            -y \
            -R ${TUNNEL_PORT}:localhost:${LOCAL_PORT} \
            ${REMOTE_USER}@${REMOTE_HOST}
    fi
    sleep 60
done
```

### 3. Make Script Executable and Add to Startup

```bash
chmod +x /usr/bin/reverse-tunnel.sh

# Add to startup
sed -i '/^exit 0/i \/usr/bin/reverse-tunnel.sh &' /etc/rc.local
```

---

## Local Machine Configuration

### 1. SSH Key Setup

```bash
# Move and rename Oracle key
mv ~/Downloads/ssh-key-2025-08-27.key ~/.ssh/oracle-tunnel
chmod 600 ~/.ssh/oracle-tunnel
```

### 2. SSH Config

Edit `~/.ssh/config`:

```
# Oracle Cloud Tunnel Server
Host oracle-tunnel
    HostName YOUR-ORACLE-IP
    User opc
    Port 22
    IdentityFile ~/.ssh/oracle-tunnel
    IdentitiesOnly yes
```

---

## Connection Commands

### Direct to Oracle Server

```bash
# Using SSH config
ssh oracle-tunnel

# Without SSH config
ssh -i ~/.ssh/oracle-tunnel -o IdentitiesOnly=yes opc@YOUR-ORACLE-IP
```

### To Router via Tunnel (Backup Access)

#### Single Command (ProxyJump)

```bash
ssh -i ~/.ssh/oracle-tunnel -o IdentitiesOnly=yes -o ProxyCommand="ssh -i ~/.ssh/oracle-tunnel -o IdentitiesOnly=yes -W %h:%p opc@YOUR-ORACLE-IP" root@localhost -p 2210
```

#### Two-Step Method

```bash
# Step 1: Connect to Oracle
ssh oracle-tunnel

# Step 2: Connect to router through tunnel
ssh root@localhost -p 2210
```

### Primary Access (Unchanged)

```bash
# Via Tailscale (primary method)
ssh root@davenport-210
```

---

## Testing and Verification

### 1. Verify Tunnel is Running

On Oracle server:

```bash
# Check listening ports
sudo ss -tlnp | grep 2210

# Should show sshd process listening on 2210
```

### 2. Test Router Connection

From Oracle server:

```bash
ssh root@localhost -p 2210
```

### 3. Test from Local Machine

```bash
# Test the ProxyJump command
ssh -i ~/.ssh/oracle-tunnel -o IdentitiesOnly=yes -o ProxyCommand="ssh -i ~/.ssh/oracle-tunnel -o IdentitiesOnly=yes -W %h:%p opc@YOUR-ORACLE-IP" root@localhost -p 2210
```

---

## Multiple Router Setup

For each additional router:

1. **Oracle Security List**: Add ingress rule for next port (2211, 2212, etc.)
2. **Oracle Firewall**: Add port to firewalld
3. **Router Script**: Use unique `TUNNEL_PORT` value
4. **Router SSH Key**: Add public key to Oracle `authorized_keys`

### Port Assignment

- Router 1 (davenport-210): Port 2210
- Router 2: Port 2211
- Router 3: Port 2212
- etc.

---

## Troubleshooting

### Common Issues

1. **"Remote TCP forward request failed"**
    
    - Check Oracle Cloud Security List ingress rules
    - Verify firewalld rules on server
    - Ensure port isn't already in use
2. **"Too many authentication failures"**
    
    - Use `IdentitiesOnly=yes` option
    - Specify key explicitly with `-i` flag
    - Check SSH agent has too many keys loaded
3. **Connection hangs**
    
    - Verify Oracle Security List rules
    - Check network connectivity with `telnet IP PORT`
    - Review SSH logs: `sudo journalctl -u sshd -f`

### Verification Commands

```bash
# On Oracle server - check active tunnels
sudo ss -tlnp | grep -E "221[0-9]"

# On router - check tunnel process
ps | grep ssh

# Test connectivity
ssh -vvv [connection-command]  # Add verbose output
```

---

## Security Notes

- Oracle Cloud Free Tier includes DDoS protection
- SSH keys provide strong authentication
- Tunnels only accept connections from localhost on Oracle server
- Regular SSH security best practices apply
- Consider changing default SSH port if desired

---

## Summary

This setup provides reliable backup access to GL.iNet routers via Oracle Cloud Free Tier, with Tailscale remaining the primary access method. The reverse tunnel automatically reconnects and survives reboots, ensuring consistent backup connectivity.




need to add to glinet script:

```bash
# Configure VPS firewall for tunnel port
if [ "$CONFIGURE_TUNNEL" = "yes" ]; then
    print_info "Configuring VPS firewall for tunnel port ${TUNNEL_PORT}..."
    if ssh -p "$VPS_SSH_PORT" "$VPS_USER@$VPS_IP" "sudo firewall-cmd --permanent --add-port=${TUNNEL_PORT}/tcp && sudo firewall-cmd --reload"; then
        print_status "VPS firewall configured for port ${TUNNEL_PORT}"
        print_info "Firewall rule: Port ${TUNNEL_PORT}/tcp allowed"
    else
        print_warning "Failed to configure VPS firewall (continuing anyway)"
        print_info "Manual step: sudo firewall-cmd --permanent --add-port=${TUNNEL_PORT}/tcp && sudo firewall-cmd --reload"
    fi
fi
```

```bash

# Add key to VPS
if [ "$CONFIGURE_TUNNEL" = "yes" ]; then
    # ... existing SSH key code ...
fi

# ADD THE NEW CODE HERE - after SSH key setup, before tunnel script creation
configure_vps_and_oracle  # or whatever you name the function

# Create unique reverse tunnel script
if [ "$CONFIGURE_TUNNEL" = "yes" ]; then
    # ... existing tunnel script creation code ...
fi
```




ocid1.user.oc1..aaaaaaaaxlor6sv7r5fx6adgkfbq6immvebuwi7nxvykmx7umk3mfayeyjda

ocid1.tenancy.oc1..aaaaaaaa6iwfkdgrdqwswiq5l7dpsiy2e77ywyqxcttki3nbp4whrtfz5nda

```bash

configure_oracle_ingress_rule() {
    if [ "$CONFIGURE_TUNNEL" = "yes" ] && [ "$KEY_AUTH_WORKS" = "yes" ]; then
        print_info "Adding Oracle Cloud ingress rule for port ${TUNNEL_PORT}..."
        
        ssh -p "$VPS_SSH_PORT" "$VPS_USER@$VPS_IP" "
            # Add firewall rule first
            sudo firewall-cmd --permanent --add-port=${TUNNEL_PORT}/tcp
            sudo firewall-cmd --reload
            
            # Add Oracle ingress rule
            SECURITY_LIST_ID='ocid1.securitylist.oc1.ca-toronto-1.aaaaaaaa7r6l2bppqe637ykv2dy6puhgnnlfrxrmvtneetshf7ztlfcij23a'
            
            # Get current rules
            oci network security-list get --security-list-id \"\$SECURITY_LIST_ID\" --query 'data.\"ingress-security-rules\"' > /tmp/current-rules.json
            
            # Create new rule with correct Oracle format
            echo '[{
                \"description\": \"SSH Tunnel - ${ROUTER_NAME}\",
                \"icmp-options\": null,
                \"is-stateless\": false,
                \"protocol\": \"6\",
                \"source\": \"0.0.0.0/0\",
                \"source-type\": \"CIDR_BLOCK\",
                \"tcp-options\": {
                    \"destination-port-range\": {
                        \"max\": ${TUNNEL_PORT},
                        \"min\": ${TUNNEL_PORT}
                    },
                    \"source-port-range\": null
                },
                \"udp-options\": null
            }]' > /tmp/new-rule.json
            
            # Combine and update
            jq -s '.[0] + .[1]' /tmp/current-rules.json /tmp/new-rule.json > /tmp/combined-rules.json
            oci network security-list update --security-list-id \"\$SECURITY_LIST_ID\" --ingress-security-rules file:///tmp/combined-rules.json --force
            
            # Cleanup
            rm -f /tmp/current-rules.json /tmp/new-rule.json /tmp/combined-rules.json
        "
    elif [ "$CONFIGURE_TUNNEL" = "yes" ]; then 
	    print_warning "SSH key not configured automatically - skipping Oracle ingress rule" 
	    print_info "Manual step: Add ingress rule for port ${TUNNEL_PORT} via Oracle Console" 
	fi
}
```




---

# BETTER SUMMARY

# Complete Oracle Cloud Setup Guide for GL.iNet Brume2 Reverse SSH Tunnels

This guide will walk through creating an Oracle Cloud Free Tier instance from scratch that works with your GL.iNet router script.

## Prerequisites

- Oracle Cloud account (free tier)
- Your router script with the 3 modified variables
- Basic understanding of SSH and command line

---

## Part 1: Oracle Cloud Account & Instance Setup

### Step 1: Create Oracle Cloud Free Tier Account

1. Go to https://cloud.oracle.com
2. Click "Start for free"
3. Complete registration (requires credit card for verification, but won't be charged)
4. Verify email and phone number
5. Wait for account activation (can take 24-48 hours)

### Step 2: Create SSH Key Pair (On Your Local Machine)

```bash
# Generate SSH key pair for Oracle access
ssh-keygen -t rsa -b 4096 -f ~/.ssh/oracle-key
# Press Enter for no passphrase (or add one if preferred)

# Display public key (you'll need this)
cat ~/.ssh/oracle-key.pub
```

Copy the entire public key output - you'll paste this into Oracle during instance creation.

### Step 3: Create Compute Instance

1. **Log into Oracle Cloud Console**
2. **Navigate to Compute**: Menu → Compute → Instances
3. **Click "Create Instance"**

**Basic Configuration:**

- **Name**: `tunnel-server` (or your preference)
- **Compartment**: Leave as default (root compartment)

**Placement:**

- **Availability Domain**: Leave default
- **Capacity Type**: On-demand capacity
- **Fault Domain**: Leave default

**Image and Shape:**

- **Image**: Oracle Linux 9 (should be default)
- **Shape**: VM.Standard.E2.1.Micro (Always Free eligible - 1 OCPU, 1GB RAM)

**Networking:**

- **Virtual Cloud Network**: Default VCN (auto-created)
- **Subnet**: Default subnet (auto-created)
- **Public IPv4 Address**: Assign a public IPv4 address (REQUIRED)
- **Public IPv4 DNS**: Leave unchecked

**SSH Keys:**

- **Add SSH Keys**: Paste public keys
- Paste the public key from Step 2
- **Save Private Key**: Download the provided private key as backup (optional)

**Boot Volume:**

- Leave defaults (50GB, Always Free eligible)

4. **Click "Create"**
5. **Wait 2-3 minutes** for instance to provision
6. **Note the Public IP** - you'll need this for your router script

---

## Part 2: Initial Instance Configuration

### Step 4: First Connection to Instance

```bash
# Test connection (replace with your public IP)
ssh -i ~/.ssh/oracle-key opc@YOUR-PUBLIC-IP

# If connection works, exit and move key to standard location
exit
mv ~/.ssh/oracle-key ~/.ssh/oracle-tunnel
chmod 600 ~/.ssh/oracle-tunnel
```

### Step 5: Update Router Script Variables

Edit your router script and update these three lines:

```bash
DEFAULT_VPS_IP="YOUR-PUBLIC-IP"    # Replace with actual Oracle IP
DEFAULT_VPS_USER="opc"             # Oracle default user
DEFAULT_VPS_SSH_PORT="22"          # Default SSH port
```

### Step 6: Basic Server Setup

```bash
# Connect to Oracle instance
ssh -i ~/.ssh/oracle-tunnel opc@YOUR-PUBLIC-IP

# Update system
sudo dnf update -y

# Install essential packages
sudo dnf install -y wget curl jq
```

---

## Part 3: SSH Configuration

### Step 7: Configure SSH for Reverse Tunnels

```bash
# Edit SSH configuration
sudo vi /etc/ssh/sshd_config

# Add or modify these lines:
GatewayPorts yes
AllowTcpForwarding yes
ClientAliveInterval 30
ClientAliveCountMax 3

# For dropbear SSH keys compatibility (GL.iNet routers)
PubkeyAcceptedKeyTypes +ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa
HostKeyAlgorithms +ssh-rsa

# Save and exit (:wq in vi)

# Restart SSH service
sudo systemctl restart sshd
sudo systemctl status sshd
```

---

## Part 4: Firewall Configuration

### Step 8: Configure OS-Level Firewall

```bash
# Check firewall status
sudo firewall-cmd --state

# SSH should already be allowed, verify
sudo firewall-cmd --list-all

# You should see 'services: dhcpv6-client ssh'
```

**Note**: We don't pre-configure tunnel ports here because your script will add them automatically.

---

## Part 5: Oracle Cloud Security Lists

### Step 9: Configure Network Security Lists

1. **Go to Oracle Cloud Console**
2. **Navigate**: Menu → Compute → Instances
3. **Click your instance name**
4. **Under Primary VNIC**: Click the **Subnet** link
5. **Click "Security Lists"**
6. **Click your security list** (usually "Default Security List for vcn-...")

**Current Rules Analysis:** You should see:

- SSH (port 22) - already configured
- ICMP rules - already configured

**Copy the Security List OCID:**

- Copy the OCID string (starts with `ocid1.securitylist.oc1...`)
- Save this - you'll need it for Oracle CLI setup

---

## Part 6: Oracle CLI Setup

### Step 10: Install Oracle CLI

```bash
# Still connected to your Oracle instance
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# Follow the prompts:
# - Install location: Press Enter for default (/home/opc/bin)
# - Add to PATH: Y
# - Install Python dependencies: Y
# - Optional packages: N

# Refresh your shell
source ~/.bashrc

# Verify installation
oci --version
```

### Step 11: Configure Oracle CLI Authentication

```bash
# Run OCI setup
oci setup config

# This will prompt for:
```

**You'll need to gather this information from Oracle Cloud Console:**

1. **User OCID**:
    
    - Console → Profile (top right) → User Settings
    - Copy the OCID string
2. **Tenancy OCID**:
    
    - Console → Profile (top right) → Tenancy: [name]
    - Copy the OCID string
3. **Region**:
    
    - Look at your console URL: `https://cloud.oracle.com/?region=ca-toronto-1`
    - The region is the part after `region=` (e.g., `ca-toronto-1`)

**Setup Prompts:**

```bash
# Enter these when prompted:
Enter a location for your config [/home/opc/.oci/config]: [Press Enter]
Enter a user OCID: ocid1.user.oc1..your-user-ocid-here
Enter a tenancy OCID: ocid1.tenancy.oc1..your-tenancy-ocid-here  
Enter a region: ca-toronto-1  # or your region
Do you want to generate a new API Signing RSA key pair?: Y
Enter a directory for your keys: [Press Enter for default]
Enter a name for your key: tunnel-key
Enter a passphrase for your private key: [Press Enter for no passphrase]
```

### Step 12: Upload API Key to Oracle

```bash
# Display the public key that was generated
cat ~/.oci/tunnel-key_public.pem
```

Copy this entire key (including BEGIN/END lines), then:

1. **Oracle Console → Profile → User Settings**
2. **Scroll to "API Keys" section**
3. **Click "Add API Key"**
4. **Paste the public key**
5. **Click "Add"**

### Step 13: Test Oracle CLI

```bash
# Test authentication
oci iam user get --user-id YOUR-USER-OCID-HERE

# Test security list access (replace with your Security List OCID)
oci network security-list get --security-list-id "YOUR-SECURITY-LIST-OCID-HERE"
```

Both commands should return JSON data without errors.

---

## Part 7: Script Integration

### Step 14: Update Router Script with Oracle CLI Function

Add this function to your router script around line 850-900:

```bash
configure_oracle_ingress_rule() {
    if [ "$CONFIGURE_TUNNEL" = "yes" ] && [ "$KEY_AUTH_WORKS" = "yes" ]; then
        print_info "Adding Oracle Cloud ingress rule for port ${TUNNEL_PORT}..."
        
        ssh -p "$VPS_SSH_PORT" "$VPS_USER@$VPS_IP" "
            # Add OS firewall rule
            sudo firewall-cmd --permanent --add-port=${TUNNEL_PORT}/tcp
            sudo firewall-cmd --reload
            
            # Add Oracle Cloud ingress rule
            SECURITY_LIST_ID='YOUR-SECURITY-LIST-OCID-HERE'
            
            # Get current ingress rules
            oci network security-list get --security-list-id \"\$SECURITY_LIST_ID\" --query 'data.\"ingress-security-rules\"' > /tmp/current-rules.json
            
            # Create new rule matching Oracle format
            echo '[{
                \"description\": \"SSH Tunnel - ${ROUTER_NAME}\",
                \"icmp-options\": null,
                \"is-stateless\": false,
                \"protocol\": \"6\",
                \"source\": \"0.0.0.0/0\",
                \"source-type\": \"CIDR_BLOCK\",
                \"tcp-options\": {
                    \"destination-port-range\": {
                        \"max\": ${TUNNEL_PORT},
                        \"min\": ${TUNNEL_PORT}
                    },
                    \"source-port-range\": null
                },
                \"udp-options\": null
            }]' > /tmp/new-rule.json
            
            # Combine current and new rules
            jq -s '.[0] + .[1]' /tmp/current-rules.json /tmp/new-rule.json > /tmp/combined-rules.json
            
            # Update security list
            oci network security-list update --security-list-id \"\$SECURITY_LIST_ID\" --ingress-security-rules file:///tmp/combined-rules.json --force
            
            # Cleanup temporary files
            rm -f /tmp/current-rules.json /tmp/new-rule.json /tmp/combined-rules.json
        "
        
        if [ $? -eq 0 ]; then
            print_status "Oracle ingress rule and firewall configured for port ${TUNNEL_PORT}"
        else
            print_warning "Failed to configure Oracle ingress rule automatically"
        fi
    elif [ "$CONFIGURE_TUNNEL" = "yes" ]; then
        print_warning "SSH key not configured automatically - skipping Oracle ingress rule"
        print_info "Manual step: Add ingress rule for port ${TUNNEL_PORT} via Oracle Console"
    fi
}
```

**Replace `YOUR-SECURITY-LIST-OCID-HERE`** with your actual Security List OCID.

### Step 15: Add Function Call to Script

Add this line in your script after the SSH key setup section:

```bash
# Add after SSH key setup, before tunnel script creation
configure_oracle_ingress_rule
```

---

## Part 8: Testing the Complete Setup

### Step 16: Test with a Router

1. **Run your script on a GL.iNet router**:
    
    ```bash
    ./gateway-setup.sh --auto testlocation 199
    ```
    
2. **Verify tunnel creation**:
    
    ```bash
    # On Oracle instance, check for tunnel
    sudo ss -tlnp | grep 2199
    
    # Should show sshd listening on port 2199
    ```
    
3. **Test tunnel connectivity**:
    
    ```bash
    # From Oracle instance, connect to router
    ssh root@localhost -p 2199
    ```
    
4. **Verify Security List rule**:
    
    ```bash
    # Check Oracle Console or use CLI
    oci network security-list get --security-list-id "YOUR-SECURITY-LIST-OCID" --query 'data."ingress-security-rules"[?description==`SSH Tunnel - testlocation-199`]'
    ```
    

---

## Part 9: Verification Checklist

### Step 17: Complete System Check

**Oracle Instance:**

- [ ] SSH access works with key authentication
- [ ] Oracle CLI installed and authenticated
- [ ] `jq` package installed
- [ ] SSH daemon configured for tunnels
- [ ] OS firewall allows SSH (port 22)

**Oracle Cloud Security:**

- [ ] Security List OCID copied and added to script
- [ ] API key uploaded to user profile
- [ ] Oracle CLI can read/modify security lists

**Router Script:**

- [ ] Three VPS variables updated with Oracle IP/user
- [ ] Oracle CLI function added with correct Security List OCID
- [ ] Function called in correct script location

**End-to-End Test:**

- [ ] Router script runs successfully
- [ ] Tunnel established (visible in `ss -tlnp`)
- [ ] Can SSH from Oracle to router via tunnel
- [ ] Security List rule created automatically
- [ ] OS firewall rule created automatically

---

## Common Issues & Solutions

**"NotAuthenticated" errors**: API key not uploaded or incorrect OCID **"Connection timeout"**: Security List not configured for SSH **"Permission denied"**: SSH keys not set up correctly **"jq: command not found"**: Package not installed (`sudo dnf install jq`) **"No such command 'add-ingress'"**: Use `update` with combined rules, not `add`

---

## Summary

This setup provides:

- Fully automated Oracle Cloud infrastructure management
- No manual Security List rule creation needed
- No manual OS firewall rule creation needed
- Complete integration with your existing router script
- Scalable to unlimited routers (each gets unique port)

Your router script now handles everything automatically when run with `--auto location-name location-id`.
#!/bin/bash
# GL.iNet Brume 2 Deployment Script
# Run this from your LOCAL machine to deploy to a new router
#
# Usage:
#   ./deploy.sh <router-ip> [location-name] [location-id]
#
# Examples:
#   ./deploy.sh 192.168.8.1                    # Interactive mode on router
#   ./deploy.sh 192.168.8.1 chicago 211        # Auto mode
#   ./deploy.sh davenport-210                  # Via Tailscale hostname

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"
CONFIG_FILE="$SCRIPT_DIR/config/defaults.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_info()    { echo -e "${YELLOW}[i]${NC} $1"; }

usage() {
    cat << EOF
GL.iNet Brume 2 Deployment Tool

Usage: $0 <router-ip> [location-name] [location-id]

Arguments:
  router-ip      IP address or Tailscale hostname of the router
  location-name  (Optional) Name for the location (e.g., chicago, denver)
  location-id    (Optional) ID for the location (100-254)

Examples:
  $0 192.168.8.1                     # Deploy with interactive setup
  $0 192.168.8.1 chicago 211         # Deploy with auto mode
  $0 davenport-210                   # Connect via Tailscale

If location-name and location-id are provided, the setup script
runs in auto mode (no prompts on the router).
EOF
    exit 1
}

# Validate arguments
[ -z "$1" ] && usage
ROUTER_HOST="$1"
LOCATION_NAME="$2"
LOCATION_ID="$3"

# Check setup script exists
if [ ! -f "$SETUP_SCRIPT" ]; then
    print_error "Setup script not found: $SETUP_SCRIPT"
    exit 1
fi

echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}     GL.iNet Brume 2 Deployment Tool${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo

# Test connection
print_info "Testing connection to $ROUTER_HOST..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$ROUTER_HOST" "echo ok" >/dev/null 2>&1; then
    print_error "Cannot connect to root@$ROUTER_HOST"
    print_info "Make sure:"
    print_info "  - Router is powered on and connected"
    print_info "  - SSH is enabled on the router"
    print_info "  - You can reach $ROUTER_HOST from this machine"
    print_info ""
    print_info "For a new router, try: ssh root@192.168.8.1"
    exit 1
fi
print_status "Connected to $ROUTER_HOST"

# Get router info
ROUTER_MODEL=$(ssh root@"$ROUTER_HOST" "cat /tmp/sysinfo/model 2>/dev/null || echo 'Unknown'")
CURRENT_HOSTNAME=$(ssh root@"$ROUTER_HOST" "uci get system.@system[0].hostname 2>/dev/null || echo 'Unknown'")
CURRENT_IP=$(ssh root@"$ROUTER_HOST" "uci get network.lan.ipaddr 2>/dev/null || echo 'Unknown'")

echo
print_info "Router: $ROUTER_MODEL"
print_info "Current hostname: $CURRENT_HOSTNAME"
print_info "Current LAN IP: $CURRENT_IP"
echo

# Copy setup script to router
print_info "Copying setup script to router..."
scp -q "$SETUP_SCRIPT" root@"$ROUTER_HOST":/tmp/setup.sh
ssh root@"$ROUTER_HOST" "chmod +x /tmp/setup.sh"
print_status "Setup script copied to /tmp/setup.sh"

# Copy config if exists
if [ -f "$CONFIG_FILE" ]; then
    print_info "Copying config to router..."
    scp -q "$CONFIG_FILE" root@"$ROUTER_HOST":/tmp/defaults.conf
    # Source config on router before running setup
    SSH_PREFIX="source /tmp/defaults.conf 2>/dev/null;"
else
    SSH_PREFIX=""
fi

# Run setup
echo
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}     Starting Setup on Router${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo

if [ -n "$LOCATION_NAME" ] && [ -n "$LOCATION_ID" ]; then
    print_info "Running in auto mode: $LOCATION_NAME-$LOCATION_ID"
    ssh -t root@"$ROUTER_HOST" "$SSH_PREFIX /tmp/setup.sh --auto $LOCATION_NAME $LOCATION_ID"
else
    print_info "Running in interactive mode"
    ssh -t root@"$ROUTER_HOST" "$SSH_PREFIX /tmp/setup.sh"
fi

# Cleanup
print_info "Cleaning up temporary files..."
ssh root@"$ROUTER_HOST" "rm -f /tmp/setup.sh /tmp/defaults.conf" 2>/dev/null || true

echo
print_status "Deployment complete!"
echo
print_info "Next steps:"
print_info "  1. Router will reboot if network settings changed"
print_info "  2. Wait 1-2 minutes for Tailscale to connect"
print_info "  3. Verify: tailscale status | grep <router-name>"
print_info "  4. Test exit node: tailscale up --exit-node=<router-name>"

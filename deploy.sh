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
#
# Workflow:
#   1. Connect new router to laptop (no internet needed for initial setup)
#   2. Run: ./deploy.sh 192.168.8.1 <name> <id>
#   3. Disconnect from laptop, connect router to ISP modem
#   4. Run: ./deploy.sh --oracle-setup <name> <id>  (after router has internet)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"
CONFIG_FILE="$SCRIPT_DIR/config/defaults.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_info()    { echo -e "${YELLOW}[i]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

usage() {
    cat << EOF
GL.iNet Brume 2 Deployment Tool

Usage: $0 <router-ip> [location-name] [location-id]
       $0 --oracle-setup <location-name> <location-id>

Arguments:
  router-ip      IP address or Tailscale hostname of the router
  location-name  Name for the location (e.g., chicago, denver)
  location-id    ID for the location (100-254)

Commands:
  --oracle-setup    Configure Oracle VPS for a router (run after router has internet)
                    Opens firewall port and adds router's SSH key

Examples:
  $0 192.168.8.1                     # Deploy with interactive setup
  $0 192.168.8.1 chicago 211         # Deploy with auto mode
  $0 davenport-210                   # Connect via Tailscale
  $0 --oracle-setup chicago 211      # Setup Oracle for chicago-211

Typical workflow for new router:
  1. Connect router to laptop (offline)
  2. ./deploy.sh 192.168.8.1 scottsdale 211
  3. Connect router to internet
  4. ./deploy.sh --oracle-setup scottsdale 211
EOF
    exit 1
}

# Load config
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        print_status "Loaded config from $CONFIG_FILE"
    else
        print_warning "Config not found: $CONFIG_FILE"
        print_info "Copy config/defaults.example.conf to config/defaults.conf"

        # Set defaults
        VPS_IP="${VPS_IP:-}"
        VPS_USER="${VPS_USER:-opc}"
        VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
    fi
}

# Validate location ID
validate_location_id() {
    local id="$1"
    [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -ge 100 ] && [ "$id" -le 254 ]
}

#############################################
# ORACLE VPS SETUP
#############################################
oracle_setup() {
    local location_name="$1"
    local location_id="$2"
    local router_name="${location_name}-${location_id}"
    local tunnel_port="2${location_id}"

    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}     Oracle VPS Setup for ${router_name}${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo

    # Load config for VPS details
    load_config

    if [ -z "$VPS_IP" ]; then
        print_error "VPS_IP not configured in $CONFIG_FILE"
        exit 1
    fi

    print_info "VPS: ${VPS_USER}@${VPS_IP}:${VPS_SSH_PORT}"
    print_info "Router: $router_name"
    print_info "Tunnel port: $tunnel_port"
    echo

    # Test VPS connection
    print_info "Testing connection to Oracle VPS..."
    if ! ssh -p "$VPS_SSH_PORT" -o ConnectTimeout=5 -o BatchMode=yes "${VPS_USER}@${VPS_IP}" "echo ok" >/dev/null 2>&1; then
        print_error "Cannot connect to ${VPS_USER}@${VPS_IP}"
        exit 1
    fi
    print_status "Connected to Oracle VPS"

    # Step 1: Open firewall port
    echo
    print_info "Step 1: Opening firewall port $tunnel_port..."

    local fw_result
    fw_result=$(ssh -p "$VPS_SSH_PORT" "${VPS_USER}@${VPS_IP}" "
        # Check if port already open
        if sudo firewall-cmd --list-ports | grep -q '${tunnel_port}/tcp'; then
            echo 'PORT_EXISTS'
        else
            sudo firewall-cmd --permanent --add-port=${tunnel_port}/tcp 2>&1 && \
            sudo firewall-cmd --reload 2>&1 && \
            echo 'PORT_ADDED'
        fi
    " 2>&1)

    if echo "$fw_result" | grep -q "PORT_EXISTS"; then
        print_status "Port $tunnel_port already open"
    elif echo "$fw_result" | grep -q "PORT_ADDED"; then
        print_status "Opened firewall port $tunnel_port"
    else
        print_warning "Firewall update may have failed: $fw_result"
        print_info "Manually run: sudo firewall-cmd --permanent --add-port=${tunnel_port}/tcp && sudo firewall-cmd --reload"
    fi

    # Step 2: Try to get router's public key via Tailscale
    echo
    print_info "Step 2: Getting router's SSH public key..."

    local router_pubkey=""

    # Try Tailscale hostname first
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${router_name}" "cat /root/.ssh/id_dropbear.pub" >/dev/null 2>&1; then
        router_pubkey=$(ssh "root@${router_name}" "cat /root/.ssh/id_dropbear.pub" 2>/dev/null)
        print_status "Retrieved key via Tailscale ($router_name)"
    else
        print_warning "Cannot reach router via Tailscale"
        print_info "Trying via tunnel..."

        # Try via existing tunnel
        if ssh -p "$VPS_SSH_PORT" "${VPS_USER}@${VPS_IP}" "ssh -p ${tunnel_port} -o ConnectTimeout=5 -o BatchMode=yes root@localhost 'cat /root/.ssh/id_dropbear.pub'" >/dev/null 2>&1; then
            router_pubkey=$(ssh -p "$VPS_SSH_PORT" "${VPS_USER}@${VPS_IP}" "ssh -p ${tunnel_port} root@localhost 'cat /root/.ssh/id_dropbear.pub'" 2>/dev/null)
            print_status "Retrieved key via tunnel"
        else
            print_warning "Cannot retrieve key automatically"
            print_info ""
            print_info "To add the key manually:"
            print_info "  1. SSH into router: ssh root@${router_name}"
            print_info "  2. Get key: cat /root/.ssh/id_dropbear.pub"
            print_info "  3. Add to Oracle: ssh ${VPS_USER}@${VPS_IP}"
            print_info "     echo '<key>' >> ~/.ssh/authorized_keys"
            echo
        fi
    fi

    # Step 3: Add router key to Oracle
    if [ -n "$router_pubkey" ]; then
        echo
        print_info "Step 3: Adding router key to Oracle..."

        # Check if key already exists (by checking for router name in comment)
        local key_check
        key_check=$(ssh -p "$VPS_SSH_PORT" "${VPS_USER}@${VPS_IP}" "grep -c 'root@${router_name}' ~/.ssh/authorized_keys 2>/dev/null || echo 0")

        if [ "$key_check" != "0" ]; then
            print_status "Key for $router_name already on Oracle"
        else
            # Add the key
            ssh -p "$VPS_SSH_PORT" "${VPS_USER}@${VPS_IP}" "echo '$router_pubkey' >> ~/.ssh/authorized_keys"
            print_status "Added key for $router_name to Oracle"
        fi
    fi

    # Step 4: Verify tunnel connectivity
    echo
    print_info "Step 4: Verifying tunnel connectivity..."
    sleep 2

    if ssh -p "$VPS_SSH_PORT" "${VPS_USER}@${VPS_IP}" "ssh -p ${tunnel_port} -o ConnectTimeout=5 -o BatchMode=yes root@localhost 'echo ok'" >/dev/null 2>&1; then
        print_status "Tunnel verified! Can SSH to router via Oracle"
        echo
        print_status "Oracle setup complete for $router_name"
        echo
        print_info "Access methods:"
        print_info "  Tailscale: ssh root@${router_name}"
        print_info "  Tunnel:    ssh -J ${VPS_USER}@${VPS_IP} -p ${tunnel_port} root@localhost"
    else
        print_warning "Tunnel not yet active"
        print_info "This may take a minute if router just connected to internet"
        print_info "Retry with: $0 --oracle-setup $location_name $location_id"
    fi

    echo
}

#############################################
# MAIN DEPLOYMENT
#############################################
deploy_to_router() {
    local router_host="$1"
    local location_name="$2"
    local location_id="$3"

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
    print_info "Testing connection to $router_host..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$router_host" "echo ok" >/dev/null 2>&1; then
        print_error "Cannot connect to root@$router_host"
        print_info "Make sure:"
        print_info "  - Router is powered on and connected"
        print_info "  - SSH is enabled on the router"
        print_info "  - You can reach $router_host from this machine"
        print_info ""
        print_info "For a new router, try: ssh root@192.168.8.1"
        exit 1
    fi
    print_status "Connected to $router_host"

    # Get router info
    ROUTER_MODEL=$(ssh root@"$router_host" "cat /tmp/sysinfo/model 2>/dev/null || echo 'Unknown'")
    CURRENT_HOSTNAME=$(ssh root@"$router_host" "uci get system.@system[0].hostname 2>/dev/null || echo 'Unknown'")
    CURRENT_IP=$(ssh root@"$router_host" "uci get network.lan.ipaddr 2>/dev/null || echo 'Unknown'")

    # Check if router has internet
    HAS_INTERNET="no"
    if ssh root@"$router_host" "wget -q --spider --timeout=3 http://google.com" 2>/dev/null; then
        HAS_INTERNET="yes"
    fi

    echo
    print_info "Router: $ROUTER_MODEL"
    print_info "Current hostname: $CURRENT_HOSTNAME"
    print_info "Current LAN IP: $CURRENT_IP"
    print_info "Internet: $([ "$HAS_INTERNET" = "yes" ] && echo "${GREEN}Connected${NC}" || echo "${YELLOW}Offline${NC}")"
    echo

    # Load config
    load_config

    # Copy setup script to router
    print_info "Copying setup script to router..."
    scp -q "$SETUP_SCRIPT" root@"$router_host":/tmp/setup.sh
    ssh root@"$router_host" "chmod +x /tmp/setup.sh"
    print_status "Setup script copied to /tmp/setup.sh"

    # Copy config if exists (for VPS settings, NextDNS, etc.)
    SSH_PREFIX=""
    if [ -f "$CONFIG_FILE" ]; then
        print_info "Copying config to router..."
        scp -q "$CONFIG_FILE" root@"$router_host":/tmp/defaults.conf
        SSH_PREFIX="source /tmp/defaults.conf 2>/dev/null; export VPS_IP VPS_USER VPS_SSH_PORT NEXTDNS_ID ORACLE_BACKUP_PUBKEY;"
    fi

    # Run setup
    echo
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}     Starting Setup on Router${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo

    if [ -n "$location_name" ] && [ -n "$location_id" ]; then
        print_info "Running in auto mode: ${location_name}-${location_id}"
        ssh -t root@"$router_host" "$SSH_PREFIX /tmp/setup.sh --auto $location_name $location_id"
    else
        print_info "Running in interactive mode"
        ssh -t root@"$router_host" "$SSH_PREFIX /tmp/setup.sh"
    fi

    # Cleanup
    print_info "Cleaning up temporary files..."
    ssh root@"$router_host" "rm -f /tmp/setup.sh /tmp/defaults.conf" 2>/dev/null || true

    echo
    print_status "Router deployment complete!"
    echo

    # Post-deployment instructions based on connectivity
    if [ "$HAS_INTERNET" = "yes" ] && [ -n "$location_name" ] && [ -n "$location_id" ]; then
        print_info "Router has internet - running Oracle setup automatically..."
        echo
        oracle_setup "$location_name" "$location_id"
    else
        print_info "Next steps:"
        print_info "  1. Router will reboot if network settings changed"
        print_info "  2. Connect router to internet (ISP modem)"
        print_info "  3. Wait 1-2 minutes for Tailscale to connect"
        if [ -n "$location_name" ] && [ -n "$location_id" ]; then
            print_info "  4. Run: ${CYAN}$0 --oracle-setup $location_name $location_id${NC}"
        else
            print_info "  4. Run: ${CYAN}$0 --oracle-setup <name> <id>${NC}"
        fi
        print_info "  5. Verify: tailscale status | grep <router-name>"
    fi
}

#############################################
# MAIN
#############################################
main() {
    # Parse arguments
    case "$1" in
        --oracle-setup)
            [ -z "$2" ] || [ -z "$3" ] && { print_error "Usage: $0 --oracle-setup <name> <id>"; exit 1; }
            validate_location_id "$3" || { print_error "Invalid location ID: $3 (must be 100-254)"; exit 1; }
            oracle_setup "$2" "$3"
            ;;
        --help|-h|"")
            usage
            ;;
        *)
            ROUTER_HOST="$1"
            LOCATION_NAME="$2"
            LOCATION_ID="$3"

            if [ -n "$LOCATION_ID" ]; then
                validate_location_id "$LOCATION_ID" || { print_error "Invalid location ID: $LOCATION_ID (must be 100-254)"; exit 1; }
            fi

            deploy_to_router "$ROUTER_HOST" "$LOCATION_NAME" "$LOCATION_ID"
            ;;
    esac
}

main "$@"

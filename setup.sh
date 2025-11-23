#!/bin/sh
# GL.iNet Brume 2 Exit Node Setup Script
# Version: 2.0
#
# This script runs ON the router to configure:
# - Tailscale as exit node
# - Reverse SSH tunnel to Oracle Cloud (backup access)
# - NextDNS (optional)
# - Network settings (hostname, LAN IP)
#
# Usage:
#   Interactive:  ./setup.sh
#   Auto mode:    ./setup.sh --auto <location-name> <location-id>
#   Example:      ./setup.sh --auto chicago 211
#
# Exit codes:
#   0 - Success
#   1 - Pre-flight check failed
#   2 - Tailscale configuration failed
#   3 - SSH tunnel configuration failed
#   4 - Network configuration failed

#############################################
# STRICT MODE AND CONFIGURATION
#############################################
SCRIPT_VERSION="2.1"
LOG_FILE="/tmp/setup-$(date +%Y%m%d-%H%M%S).log"

# Defaults (override via environment variables)
: "${VPS_IP:=40.233.108.14}"
: "${VPS_USER:=opc}"
: "${VPS_SSH_PORT:=22}"
: "${TAILSCALE_AUTHKEY:=}"
: "${NEXTDNS_ID:=43d323}"
: "${SKIP_TAILSCALE_UPDATE:=no}"
: "${SKIP_SSH_TUNNEL:=no}"
: "${ORACLE_BACKUP_PUBKEY:=}"

#############################################
# LOGGING AND OUTPUT
#############################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Log to both console and file
log() {
    local level="$1" msg="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

print_status() {
    printf "${GREEN}[✓]${NC} %s\n" "$1"
    log "OK" "$1"
}

print_error() {
    printf "${RED}[✗]${NC} %s\n" "$1" >&2
    log "ERROR" "$1"
}

print_info() {
    printf "${YELLOW}[i]${NC} %s\n" "$1"
    log "INFO" "$1"
}

print_warning() {
    printf "${YELLOW}[!]${NC} %s\n" "$1"
    log "WARN" "$1"
}

print_debug() {
    [ "$DEBUG" = "yes" ] && printf "${CYAN}[D]${NC} %s\n" "$1"
    log "DEBUG" "$1"
}

# Fatal error - exit with message
die() {
    print_error "$1"
    print_error "Setup failed. Log file: $LOG_FILE"
    exit "${2:-1}"
}

#############################################
# VALIDATION FUNCTIONS
#############################################
validate_location_name() {
    local name="$1"
    [ -z "$name" ] && return 1
    echo "$name" | grep -qE '^[a-zA-Z][a-zA-Z0-9-]{1,17}$'
}

validate_location_id() {
    local id="$1"
    [ -z "$id" ] && return 1
    # Check it's a number in range 100-254
    # This ensures tunnel ports are 2100-2254 (avoiding well-known ports)
    case "$id" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$id" -ge 100 ] && [ "$id" -le 254 ]
}

validate_nextdns_id() {
    local id="$1"
    [ -z "$id" ] && return 1
    echo "$id" | grep -qE '^[a-zA-Z0-9]{6}$'
}

validate_authkey() {
    local key="$1"
    [ -z "$key" ] && return 1
    echo "$key" | grep -qE '^tskey-auth-[a-zA-Z0-9]+'
}

validate_ip() {
    local ip="$1"
    echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

#############################################
# UTILITY FUNCTIONS
#############################################
prompt_valid() {
    local prompt="$1" validation_func="$2" error_msg="$3" value
    local max_attempts=5 attempt=0

    while [ $attempt -lt $max_attempts ]; do
        printf "%s" "$prompt"
        read value
        if $validation_func "$value"; then
            echo "$value"
            return 0
        fi
        print_error "$error_msg"
        attempt=$((attempt + 1))
    done

    die "Too many invalid inputs" 1
}

prompt_yes_no() {
    local prompt="$1" default="$2" response
    printf "%s" "$prompt"
    read response
    case "$response" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        "") [ "$default" = "y" ] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

# Make RPC call with error handling
rpc_call() {
    local module="$1" method="$2" params="$3"
    local response

    print_debug "RPC: $module.$method($params)"

    response=$(curl -H 'glinet: 1' -s -k --connect-timeout 5 --max-time 10 \
        http://127.0.0.1/rpc -d \
        "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"$module\",\"$method\",$params],\"id\":1}" 2>&1)

    if [ $? -ne 0 ]; then
        print_debug "RPC curl failed: $response"
        return 1
    fi

    # Check for RPC error
    if echo "$response" | grep -q '"error"'; then
        local error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1)
        print_debug "RPC error: $error_msg"
        return 1
    fi

    # Check for result
    if echo "$response" | grep -q '"result"'; then
        echo "$response"
        return 0
    fi

    print_debug "RPC unexpected response: $response"
    return 1
}

# Check if command exists
cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Retry a command with exponential backoff
retry() {
    local max_attempts="$1" cmd="$2"
    local attempt=1 wait_time=2

    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        fi
        print_debug "Attempt $attempt/$max_attempts failed, waiting ${wait_time}s..."
        sleep $wait_time
        wait_time=$((wait_time * 2))
        attempt=$((attempt + 1))
    done

    return 1
}

#############################################
# PRE-FLIGHT CHECKS
#############################################
preflight_checks() {
    printf "\n${BLUE}=== Pre-flight Checks ===${NC}\n\n"
    local failed=0

    # Check we're running as root
    if [ "$(id -u)" != "0" ]; then
        print_error "Must run as root"
        failed=1
    else
        print_status "Running as root"
    fi

    # Check required commands
    local required_cmds="curl wget uci grep sed chmod cat mkdir"
    for cmd in $required_cmds; do
        if cmd_exists "$cmd"; then
            print_debug "Command available: $cmd"
        else
            print_error "Required command not found: $cmd"
            failed=1
        fi
    done
    print_status "Required commands available"

    # Check RPC API is accessible
    if rpc_call "system" "get_info" "{}" >/dev/null; then
        print_status "GL.iNet RPC API accessible"
    else
        print_error "GL.iNet RPC API not accessible"
        failed=1
    fi

    # Check internet connectivity
    if wget -q --spider --timeout=5 http://google.com 2>/dev/null; then
        print_status "Internet connectivity OK"
    else
        print_warning "No internet - Tailscale update will be skipped"
        SKIP_TAILSCALE_UPDATE="yes"
    fi

    # Check filesystem is writable
    if touch /tmp/.write_test 2>/dev/null; then
        rm -f /tmp/.write_test
        print_status "Filesystem writable"
    else
        print_error "Filesystem not writable"
        failed=1
    fi

    # Check /usr/bin is writable (for scripts)
    if touch /usr/bin/.write_test 2>/dev/null; then
        rm -f /usr/bin/.write_test
        print_status "/usr/bin writable"
    else
        print_error "/usr/bin not writable - may need to remount"
        # Try to remount
        if [ -f /lib/functions/gl_util.sh ]; then
            . /lib/functions/gl_util.sh
            remount_ubifs 2>/dev/null
            if touch /usr/bin/.write_test 2>/dev/null; then
                rm -f /usr/bin/.write_test
                print_status "/usr/bin now writable after remount"
            else
                failed=1
            fi
        else
            failed=1
        fi
    fi

    # Check VPS is reachable (if tunnel not skipped)
    if [ "$SKIP_SSH_TUNNEL" != "yes" ]; then
        if ping -c 1 -W 3 "$VPS_IP" >/dev/null 2>&1; then
            print_status "VPS reachable ($VPS_IP)"
        else
            print_warning "VPS not reachable - tunnel setup may fail"
        fi
    fi

    # Check disk space (need at least 1MB free)
    local free_space=$(df /usr/bin 2>/dev/null | tail -1 | awk '{print $4}')
    if [ -n "$free_space" ] && [ "$free_space" -gt 1024 ]; then
        print_status "Sufficient disk space (${free_space}KB free)"
    else
        print_warning "Low disk space - may cause issues"
    fi

    if [ $failed -ne 0 ]; then
        die "Pre-flight checks failed" 1
    fi

    print_status "All pre-flight checks passed"
    log "INFO" "Pre-flight checks completed successfully"
}

#############################################
# TAILSCALE FUNCTIONS
#############################################
check_tailscale_daemon() {
    pidof tailscaled >/dev/null 2>&1
}

check_tailscale_authenticated() {
    local status
    status=$(tailscale status 2>&1)

    # Check various states
    if echo "$status" | grep -q "Logged out"; then
        return 1
    elif echo "$status" | grep -q "not logged in"; then
        return 1
    elif echo "$status" | grep -q "^100\."; then
        return 0  # Has Tailscale IP, is authenticated
    fi

    return 1
}

get_tailscale_ip() {
    tailscale ip -4 2>/dev/null | head -1
}

enable_tailscale_via_rpc() {
    print_info "Enabling Tailscale via GL.iNet RPC API..."

    if ! rpc_call "tailscale" "set_config" '{"enabled":true}' >/dev/null; then
        print_error "RPC call failed"
        return 1
    fi

    print_status "Tailscale enable command sent"

    # Wait for daemon to start (with timeout)
    print_info "Waiting for Tailscale daemon to start..."
    local attempt=0 max_attempts=12  # 60 seconds total

    while [ $attempt -lt $max_attempts ]; do
        if check_tailscale_daemon; then
            print_status "Tailscale daemon running"
            return 0
        fi
        sleep 5
        attempt=$((attempt + 1))
        print_debug "Waiting for daemon... ($attempt/$max_attempts)"
    done

    print_error "Tailscale daemon did not start within 60 seconds"
    return 1
}

update_tailscale() {
    if [ "$SKIP_TAILSCALE_UPDATE" = "yes" ]; then
        print_info "Skipping Tailscale update (no internet or explicitly skipped)"
        return 0
    fi

    print_info "Downloading Tailscale updater..."

    local updater="/tmp/update-tailscale.sh"
    local url="https://raw.githubusercontent.com/Admonstrator/glinet-tailscale-updater/main/update-tailscale.sh"

    if ! wget -q -O "$updater" "$url" 2>/dev/null; then
        print_warning "Failed to download Tailscale updater - continuing with existing version"
        return 0  # Non-fatal
    fi

    if [ ! -s "$updater" ]; then
        print_warning "Downloaded updater is empty - continuing with existing version"
        rm -f "$updater"
        return 0
    fi

    print_info "Running Tailscale updater (this may take a few minutes)..."

    # Run updater and capture output
    local update_output
    update_output=$(sh "$updater" --force 2>&1)
    local update_result=$?

    rm -f "$updater"

    if [ $update_result -eq 0 ]; then
        local version=$(tailscale version 2>/dev/null | head -1)
        print_status "Tailscale updated to $version"
    else
        print_warning "Tailscale update returned non-zero, but may have succeeded"
        print_debug "Update output: $update_output"
    fi

    # Verify daemon is still running
    sleep 2
    if check_tailscale_daemon; then
        return 0
    else
        print_info "Restarting Tailscale daemon..."
        /etc/init.d/tailscale restart 2>/dev/null
        sleep 3
        check_tailscale_daemon
    fi
}

authenticate_tailscale() {
    local authkey="$1"

    # Check if already authenticated
    if check_tailscale_authenticated; then
        local current_ip=$(get_tailscale_ip)
        print_status "Tailscale already authenticated (IP: $current_ip)"

        # Still need to ensure exit node is advertised
        print_info "Ensuring exit node is advertised..."
        tailscale up --advertise-exit-node --hostname="$ROUTER_NAME" \
            --accept-routes --accept-dns=false 2>/dev/null
        return 0
    fi

    print_info "Authenticating Tailscale..."
    print_debug "Using hostname: $ROUTER_NAME"

    # Attempt authentication
    local auth_output
    auth_output=$(tailscale up \
        --auth-key="$authkey" \
        --hostname="$ROUTER_NAME" \
        --advertise-exit-node \
        --accept-routes \
        --accept-dns=false 2>&1)
    local auth_result=$?

    if [ $auth_result -ne 0 ]; then
        print_error "Tailscale authentication failed"
        print_debug "Output: $auth_output"

        # Check for specific errors
        if echo "$auth_output" | grep -qi "invalid.*key\|key.*invalid\|expired"; then
            print_error "Auth key appears to be invalid or expired"
            print_info "Generate a new key at: https://login.tailscale.com/admin/settings/keys"
        fi

        return 1
    fi

    # Verify authentication
    sleep 3
    if check_tailscale_authenticated; then
        local ts_ip=$(get_tailscale_ip)
        print_status "Tailscale authenticated as $ROUTER_NAME (IP: $ts_ip)"
        return 0
    else
        print_error "Authentication command succeeded but device not authenticated"
        return 1
    fi
}

patch_gl_tailscale() {
    local gl_tailscale="/usr/bin/gl_tailscale"

    if [ ! -f "$gl_tailscale" ]; then
        print_warning "gl_tailscale not found - exit node setting may not persist"
        return 0
    fi

    if grep -q "advertise-exit-node" "$gl_tailscale"; then
        print_status "gl_tailscale already patched for exit node"
        return 0
    fi

    print_info "Patching gl_tailscale for exit node persistence..."

    # Create backup
    cp "$gl_tailscale" "${gl_tailscale}.backup.$(date +%Y%m%d)"

    # Patch the file
    if sed -i 's|/usr/sbin/tailscale up --reset|/usr/sbin/tailscale up --advertise-exit-node --reset|g' "$gl_tailscale"; then
        print_status "Patched gl_tailscale"
    else
        print_warning "Failed to patch gl_tailscale"
        # Restore backup
        cp "${gl_tailscale}.backup.$(date +%Y%m%d)" "$gl_tailscale"
    fi
}

create_tailscale_watchdog() {
    local watchdog="/usr/bin/keep-tailscale-alive.sh"

    print_info "Creating Tailscale watchdog script..."

    cat > "$watchdog" << 'WATCHDOG_EOF'
#!/bin/sh
# Tailscale watchdog - auto-generated
# Runs via cron every 5 minutes

ROUTER_NAME="__ROUTER_NAME__"
STATE_FILE="/tmp/tailscale-state"
LOG_TAG="tailscale-watchdog"

log_msg() { logger -t "$LOG_TAG" "$1"; }
get_state() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "unknown"; }
set_state() { echo "$1" > "$STATE_FILE"; }

# Check if Tailscale is working
if ! /usr/sbin/tailscale status >/dev/null 2>&1; then
    prev_state=$(get_state)

    if [ "$prev_state" != "down" ]; then
        log_msg "[$ROUTER_NAME] Tailscale down, attempting recovery"
        set_state "down"
    fi

    # Try to recover
    /usr/sbin/tailscale up --advertise-exit-node --hostname "$ROUTER_NAME" \
        --accept-routes --accept-dns=false 2>/dev/null

    /etc/init.d/tailscale restart 2>/dev/null
    sleep 5

    if /usr/sbin/tailscale status >/dev/null 2>&1; then
        log_msg "[$ROUTER_NAME] Tailscale recovered successfully"
        set_state "up"
    else
        log_msg "[$ROUTER_NAME] Tailscale recovery failed"
    fi
else
    prev_state=$(get_state)
    if [ "$prev_state" != "up" ]; then
        log_msg "[$ROUTER_NAME] Tailscale confirmed active"
        set_state "up"
    fi
fi
WATCHDOG_EOF

    # Replace placeholder with actual router name
    sed -i "s/__ROUTER_NAME__/$ROUTER_NAME/g" "$watchdog"
    chmod +x "$watchdog"

    print_status "Created $watchdog"

    # Setup cron
    mkdir -p /etc/crontabs
    if ! grep -q "keep-tailscale-alive" /etc/crontabs/root 2>/dev/null; then
        echo "*/5 * * * * $watchdog >/dev/null 2>&1" >> /etc/crontabs/root
        /etc/init.d/cron restart >/dev/null 2>&1 || true
        print_status "Added watchdog to cron (every 5 min)"
    else
        print_status "Watchdog cron job already exists"
    fi
}

configure_tailscale() {
    printf "\n${BLUE}=== Tailscale Configuration ===${NC}\n\n"

    # Step 1: Enable if not running
    if ! check_tailscale_daemon; then
        print_info "Tailscale daemon not running"
        if ! enable_tailscale_via_rpc; then
            print_error "Could not enable Tailscale"
            print_info "Try enabling manually: Admin Panel → Applications → Tailscale → ON"
            return 1
        fi
    else
        print_status "Tailscale daemon already running"
    fi

    # Step 2: Update (non-fatal if fails)
    update_tailscale

    # Step 3: Get auth key if needed
    if [ -z "$TAILSCALE_AUTHKEY" ] && ! check_tailscale_authenticated; then
        printf "\n"
        print_info "Tailscale authentication required"
        print_info "Generate a key at: ${CYAN}https://login.tailscale.com/admin/settings/keys${NC}"
        print_info "  • Enable 'Reusable' for multiple routers"
        print_info "  • Keys expire after 90 days maximum"
        printf "\n"

        TAILSCALE_AUTHKEY=$(prompt_valid "Auth Key: " "validate_authkey" "Must start with 'tskey-auth-'")
    fi

    # Step 4: Authenticate
    if [ -n "$TAILSCALE_AUTHKEY" ] || ! check_tailscale_authenticated; then
        if ! authenticate_tailscale "$TAILSCALE_AUTHKEY"; then
            return 1
        fi
    fi

    # Step 5: Patch gl_tailscale
    patch_gl_tailscale

    # Step 6: Create watchdog
    create_tailscale_watchdog

    print_status "Tailscale configuration complete"
    return 0
}

#############################################
# SSH TUNNEL FUNCTIONS
#############################################
generate_ssh_key() {
    local key_file="/root/.ssh/id_dropbear"
    local pub_file="${key_file}.pub"

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    if [ -f "$key_file" ] && [ -f "$pub_file" ]; then
        print_status "SSH key already exists"
        return 0
    fi

    print_info "Generating SSH key..."

    if ! cmd_exists dropbearkey; then
        print_error "dropbearkey not found - cannot generate SSH key"
        return 1
    fi

    # Generate key
    if ! dropbearkey -t rsa -f "$key_file" -s 2048 >/dev/null 2>&1; then
        print_error "Failed to generate SSH key"
        return 1
    fi

    # Extract public key with router-specific comment
    local raw_key=$(dropbearkey -y -f "$key_file" 2>/dev/null | grep "^ssh-rsa")
    if [ -z "$raw_key" ]; then
        print_error "Failed to extract public key"
        rm -f "$key_file"
        return 1
    fi

    # Replace generic comment with router name for identification
    echo "$raw_key" | sed "s/root@.*$/root@${ROUTER_NAME}/" > "$pub_file"

    chmod 600 "$key_file"
    print_status "Generated SSH key (RSA 2048-bit) for $ROUTER_NAME"
    return 0
}

# Pre-add Oracle/VPS host key to known_hosts (prevents SSH hanging)
setup_vps_known_host() {
    local known_hosts="/root/.ssh/known_hosts"

    # Check if already in known_hosts
    if grep -q "$VPS_IP" "$known_hosts" 2>/dev/null; then
        print_debug "VPS already in known_hosts"
        return 0
    fi

    print_info "Adding VPS to known_hosts..."
    mkdir -p /root/.ssh

    # For dropbear, we just need to accept on first connection
    # The -y flag auto-accepts, but we can also pre-populate
    # Try to get the host key (requires connectivity)
    if ping -c 1 -W 2 "$VPS_IP" >/dev/null 2>&1; then
        # Use ssh-keyscan if available, otherwise rely on -y flag
        if cmd_exists ssh-keyscan; then
            ssh-keyscan -p "$VPS_SSH_PORT" "$VPS_IP" >> "$known_hosts" 2>/dev/null
            print_status "Added VPS host key to known_hosts"
        else
            print_debug "ssh-keyscan not available, will auto-accept on first connect"
        fi
    else
        print_debug "VPS not reachable, will auto-accept host key later"
    fi
    return 0
}

# Add Oracle/VPS public key to router for backup access FROM Oracle
setup_vps_backup_access() {
    local auth_keys="/etc/dropbear/authorized_keys"

    # Oracle backup key is configured via ORACLE_BACKUP_PUBKEY in config
    if [ -z "$ORACLE_BACKUP_PUBKEY" ]; then
        print_debug "ORACLE_BACKUP_PUBKEY not set - skipping VPS backup access"
        return 0
    fi

    if grep -q "oracle-backup-access" "$auth_keys" 2>/dev/null; then
        print_debug "Oracle backup access key already configured"
        return 0
    fi

    print_info "Configuring backup access from VPS..."
    mkdir -p /etc/dropbear
    echo "$ORACLE_BACKUP_PUBKEY" >> "$auth_keys"
    chmod 600 "$auth_keys"
    print_status "VPS backup access configured"
    return 0
}

test_vps_ssh() {
    print_info "Testing SSH connection to VPS..."

    if ssh -p "$VPS_SSH_PORT" \
           -o ConnectTimeout=10 \
           -o PasswordAuthentication=no \
           -o BatchMode=yes \
           -o StrictHostKeyChecking=no \
           "$VPS_USER@$VPS_IP" "echo ok" >/dev/null 2>&1; then
        print_status "SSH connection to VPS successful"
        return 0
    else
        print_debug "SSH connection failed"
        return 1
    fi
}

setup_vps_key() {
    local pubkey=$(cat /root/.ssh/id_dropbear.pub 2>/dev/null)

    if [ -z "$pubkey" ]; then
        print_error "No public key found"
        return 1
    fi

    # If we can already connect, add key
    if test_vps_ssh; then
        print_info "Adding router key to VPS authorized_keys..."

        if ssh -p "$VPS_SSH_PORT" "$VPS_USER@$VPS_IP" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
             grep -qxF '$pubkey' ~/.ssh/authorized_keys 2>/dev/null || \
             echo '$pubkey' >> ~/.ssh/authorized_keys && \
             chmod 600 ~/.ssh/authorized_keys" 2>/dev/null; then
            print_status "Router key added to VPS"
            return 0
        else
            print_warning "Could not add key automatically"
        fi
    fi

    # Manual setup required
    printf "\n"
    print_warning "Manual SSH key setup required"
    printf "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "Add this key to: ${GREEN}%s@%s:~/.ssh/authorized_keys${NC}\n\n" "$VPS_USER" "$VPS_IP"
    printf "${CYAN}%s${NC}\n\n" "$pubkey"
    printf "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    if [ "$AUTO_MODE" = "yes" ]; then
        print_warning "Auto mode: Continuing without VPS key verification"
        return 0
    fi

    printf "Press Enter after adding the key (or 'skip' to continue without tunnel)... "
    read response

    if [ "$response" = "skip" ]; then
        SKIP_SSH_TUNNEL="yes"
        return 0
    fi

    # Verify it works now
    if test_vps_ssh; then
        print_status "VPS connection verified"
        return 0
    else
        print_warning "Still cannot connect - tunnel may not work"
        return 0  # Continue anyway
    fi
}

create_tunnel_script() {
    local script="/usr/bin/reverse-tunnel-${LOCATION_ID}.sh"

    print_info "Creating reverse tunnel script..."

    cat > "$script" << 'TUNNEL_EOF'
#!/bin/sh
# Reverse SSH tunnel - auto-generated
# Maintains persistent connection to VPS for backup access

REMOTE_HOST="__VPS_IP__"
REMOTE_USER="__VPS_USER__"
REMOTE_PORT="__VPS_SSH_PORT__"
TUNNEL_PORT="__TUNNEL_PORT__"
ROUTER_NAME="__ROUTER_NAME__"
STATE_FILE="/tmp/tunnel-__LOCATION_ID__-state"
LOG_TAG="ssh-tunnel"

log_msg() { logger -t "$LOG_TAG" "$1"; }
get_state() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "unknown"; }
set_state() { echo "$1" > "$STATE_FILE"; }

# Check if tunnel SSH process is running
is_tunnel_up() {
    pgrep -f "ssh.*-R.*${TUNNEL_PORT}:localhost" >/dev/null 2>&1
}

# Main loop
while true; do
    if ! is_tunnel_up; then
        prev_state=$(get_state)
        [ "$prev_state" != "down" ] && log_msg "[$ROUTER_NAME] Tunnel down, reconnecting..." && set_state "down"

        # Establish tunnel
        ssh -p "$REMOTE_PORT" \
            -N -f \
            -o ExitOnForwardFailure=yes \
            -o ServerAliveInterval=30 \
            -o ServerAliveCountMax=3 \
            -o ConnectTimeout=30 \
            -o StrictHostKeyChecking=no \
            -o BatchMode=yes \
            -K 60 -y \
            -R "${TUNNEL_PORT}:localhost:22" \
            "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null

        if [ $? -eq 0 ]; then
            log_msg "[$ROUTER_NAME] Tunnel established on port $TUNNEL_PORT"
            set_state "up"
        else
            log_msg "[$ROUTER_NAME] Tunnel connection failed"
        fi
    else
        prev_state=$(get_state)
        [ "$prev_state" != "up" ] && log_msg "[$ROUTER_NAME] Tunnel confirmed active" && set_state "up"
    fi

    sleep 60
done
TUNNEL_EOF

    # Replace placeholders
    sed -i "s|__VPS_IP__|$VPS_IP|g" "$script"
    sed -i "s|__VPS_USER__|$VPS_USER|g" "$script"
    sed -i "s|__VPS_SSH_PORT__|$VPS_SSH_PORT|g" "$script"
    sed -i "s|__TUNNEL_PORT__|$TUNNEL_PORT|g" "$script"
    sed -i "s|__ROUTER_NAME__|$ROUTER_NAME|g" "$script"
    sed -i "s|__LOCATION_ID__|$LOCATION_ID|g" "$script"

    chmod +x "$script"
    print_status "Created $script"

    # Add to startup
    setup_tunnel_autostart "$script"

    return 0
}

setup_tunnel_autostart() {
    local script="$1"
    local rc_local="/etc/rc.local"

    # Ensure rc.local exists with proper structure
    if [ ! -f "$rc_local" ]; then
        cat > "$rc_local" << 'RC_EOF'
#!/bin/sh /etc/rc.common

# Load GL.iNet utilities if available
[ -f /lib/functions/gl_util.sh ] && . /lib/functions/gl_util.sh && remount_ubifs

exit 0
RC_EOF
        chmod +x "$rc_local"
    fi

    # Add tunnel script if not already present
    if ! grep -q "$script" "$rc_local"; then
        # Insert before 'exit 0'
        sed -i "/^exit 0/i\\
# Reverse SSH tunnel for ${ROUTER_NAME}\\
${script} \&\\
" "$rc_local"
        print_status "Added tunnel to startup"
    else
        print_status "Tunnel already in startup"
    fi
}

start_tunnel() {
    local script="/usr/bin/reverse-tunnel-${LOCATION_ID}.sh"

    print_info "Starting tunnel..."

    # Kill any existing tunnel for this location
    pkill -f "reverse-tunnel-${LOCATION_ID}" 2>/dev/null || true
    sleep 1

    # Start new tunnel
    "$script" &
    sleep 3

    # Check if tunnel process is running
    if pgrep -f "reverse-tunnel-${LOCATION_ID}" >/dev/null; then
        # Check if SSH tunnel is actually established
        sleep 2
        if pgrep -f "ssh.*-R.*${TUNNEL_PORT}:localhost" >/dev/null; then
            print_status "Tunnel running on port $TUNNEL_PORT"
            return 0
        else
            print_warning "Tunnel script running but SSH not yet connected"
            print_info "Tunnel will retry automatically"
            return 0
        fi
    else
        print_warning "Tunnel script may have exited - check logs"
        return 0  # Non-fatal
    fi
}

configure_ssh_tunnel() {
    if [ "$SKIP_SSH_TUNNEL" = "yes" ]; then
        print_info "Skipping SSH tunnel configuration"
        return 0
    fi

    printf "\n${BLUE}=== SSH Tunnel Configuration ===${NC}\n\n"
    print_info "Tunnel: localhost:22 → $VPS_USER@$VPS_IP:$TUNNEL_PORT"
    printf "\n"

    # Step 1: Generate SSH key (with router-specific comment)
    if ! generate_ssh_key; then
        print_warning "SSH key generation failed - skipping tunnel"
        return 0  # Non-fatal
    fi

    # Step 2: Pre-add VPS to known_hosts (prevents SSH hanging on first connect)
    setup_vps_known_host

    # Step 3: Configure backup access FROM VPS to router
    setup_vps_backup_access

    # Step 4: Setup router key on VPS
    setup_vps_key

    if [ "$SKIP_SSH_TUNNEL" = "yes" ]; then
        return 0
    fi

    # Step 5: Create tunnel script
    create_tunnel_script

    # Step 6: Start tunnel
    start_tunnel

    print_status "SSH tunnel configuration complete"
    return 0
}

#############################################
# NETWORK CONFIGURATION
#############################################
configure_hostname_uci() {
    local current=$(uci get system.@system[0].hostname 2>/dev/null)

    if [ "$current" = "$ROUTER_NAME" ]; then
        print_status "Hostname already set to $ROUTER_NAME"
        return 0
    fi

    print_info "Setting hostname: $current → $ROUTER_NAME"

    if ! uci set system.@system[0].hostname="$ROUTER_NAME"; then
        print_error "Failed to set hostname"
        return 1
    fi

    if ! uci commit system; then
        print_error "Failed to commit hostname change"
        return 1
    fi

    print_status "Hostname configured"
    return 0
}

configure_lan_ip_uci() {
    local current=$(uci get network.lan.ipaddr 2>/dev/null)

    if [ "$current" = "$GATEWAY_IP" ]; then
        print_status "LAN IP already set to $GATEWAY_IP"
        return 0
    fi

    print_info "Setting LAN IP: $current → $GATEWAY_IP"
    print_warning "This will change the router's IP address!"

    if ! uci set network.lan.ipaddr="$GATEWAY_IP"; then
        print_error "Failed to set LAN IP"
        return 1
    fi

    if ! uci commit network; then
        print_error "Failed to commit network change"
        return 1
    fi

    NETWORK_CHANGED="yes"
    print_status "LAN IP configured (requires reboot)"
    return 0
}

configure_dns_rpc() {
    printf "\n${BLUE}=== DNS Configuration ===${NC}\n\n"

    local use_nextdns="n"

    if [ "$AUTO_MODE" = "yes" ]; then
        use_nextdns="y"
    else
        prompt_yes_no "Configure NextDNS? (Y/n): " "y" && use_nextdns="y"
    fi

    if [ "$use_nextdns" != "y" ]; then
        print_info "Skipping NextDNS configuration"
        return 0
    fi

    # Get NextDNS ID if not set
    if ! validate_nextdns_id "$NEXTDNS_ID"; then
        NEXTDNS_ID=$(prompt_valid "NextDNS ID (6 chars): " "validate_nextdns_id" "Must be 6 alphanumeric characters")
    fi

    print_info "Configuring NextDNS ($NEXTDNS_ID) via RPC API..."

    local dns_params="{\"mode\":\"secure\",\"force_dns\":true,\"override_vpn\":true,\"dot_provider\":\"1\",\"nextdns_id\":\"$NEXTDNS_ID\",\"proto\":\"DoT\"}"

    if rpc_call "dns" "set_config" "$dns_params" >/dev/null; then
        print_status "NextDNS configured (ID: $NEXTDNS_ID)"

        # Verify
        local verify=$(rpc_call "dns" "get_config" "{}" 2>/dev/null)
        if echo "$verify" | grep -q "\"nextdns_id\":\"$NEXTDNS_ID\""; then
            print_debug "DNS configuration verified"
        fi
    else
        print_warning "NextDNS configuration may have failed"
        print_info "You can configure DNS manually in Admin Panel → Network → DNS"
    fi

    return 0
}

configure_network() {
    printf "\n${BLUE}=== Network Configuration ===${NC}\n\n"

    configure_hostname_uci || return 1
    configure_lan_ip_uci || return 1
    configure_dns_rpc

    print_status "Network configuration complete"
    return 0
}

#############################################
# PERSISTENCE AND CLEANUP
#############################################
configure_persistence() {
    print_info "Configuring persistence for firmware upgrades..."

    local sysupgrade="/etc/sysupgrade.conf"
    local files_to_keep="
/usr/bin/keep-tailscale-alive.sh
/usr/bin/reverse-tunnel-${LOCATION_ID}.sh
/usr/bin/gl_tailscale
/root/.ssh/
/etc/crontabs/root
/etc/rc.local
"

    # Add header if file is empty or doesn't exist
    if [ ! -s "$sysupgrade" ]; then
        echo "# Files to keep during firmware upgrade" > "$sysupgrade"
    fi

    # Add each file if not already present
    for file in $files_to_keep; do
        file=$(echo "$file" | tr -d ' ')
        [ -z "$file" ] && continue
        if ! grep -qxF "$file" "$sysupgrade" 2>/dev/null; then
            echo "$file" >> "$sysupgrade"
        fi
    done

    print_status "Persistence configured"
}

create_deployment_record() {
    local record="/etc/router-deployment.info"

    cat > "$record" << EOF
# Router Deployment Record
# Generated: $(date)

ROUTER_NAME=$ROUTER_NAME
LOCATION_NAME=$LOCATION_NAME
LOCATION_ID=$LOCATION_ID
GATEWAY_IP=$GATEWAY_IP
TUNNEL_PORT=$TUNNEL_PORT
VPS_ENDPOINT=$VPS_USER@$VPS_IP:$VPS_SSH_PORT
TAILSCALE_IP=$(get_tailscale_ip)
SETUP_VERSION=$SCRIPT_VERSION
SETUP_DATE=$(date +%Y-%m-%d)
EOF

    print_status "Deployment record saved to $record"
}

#############################################
# MAIN
#############################################
main() {
    # Initialize log
    echo "=== GL.iNet Setup v$SCRIPT_VERSION ===" > "$LOG_FILE"
    echo "Started: $(date)" >> "$LOG_FILE"
    echo "Arguments: $*" >> "$LOG_FILE"

    # Banner
    clear
    printf "${BLUE}════════════════════════════════════════════════════════════════${NC}\n"
    printf "${BLUE}       GL.iNet Brume 2 Exit Node Setup v${SCRIPT_VERSION}${NC}\n"
    printf "${BLUE}════════════════════════════════════════════════════════════════${NC}\n\n"

    # Parse arguments
    AUTO_MODE="no"
    while [ $# -gt 0 ]; do
        case "$1" in
            --auto)
                AUTO_MODE="yes"
                shift
                [ -n "$1" ] && LOCATION_NAME="$1" && shift
                [ -n "$1" ] && LOCATION_ID="$1" && shift
                ;;
            --skip-tailscale-update)
                SKIP_TAILSCALE_UPDATE="yes"
                shift
                ;;
            --skip-tunnel)
                SKIP_SSH_TUNNEL="yes"
                shift
                ;;
            --debug)
                DEBUG="yes"
                shift
                ;;
            --help|-h)
                printf "Usage: %s [OPTIONS]\n\n" "$0"
                printf "Options:\n"
                printf "  --auto <name> <id>      Run in auto mode\n"
                printf "  --skip-tailscale-update Skip Tailscale update\n"
                printf "  --skip-tunnel           Skip SSH tunnel setup\n"
                printf "  --debug                 Enable debug output\n"
                printf "  --help                  Show this help\n"
                exit 0
                ;;
            *)
                print_warning "Unknown argument: $1"
                shift
                ;;
        esac
    done

    # Get location info if not in auto mode
    if [ "$AUTO_MODE" != "yes" ] || [ -z "$LOCATION_NAME" ] || [ -z "$LOCATION_ID" ]; then
        AUTO_MODE="no"
        printf "${YELLOW}Location Configuration${NC}\n"
        printf "The location name and ID determine the router's identity:\n"
        printf "  • Hostname: <name>-<id> (e.g., chicago-211)\n"
        printf "  • Gateway:  192.168.<id>.1\n"
        printf "  • Tunnel:   Port 2<id>\n\n"

        LOCATION_NAME=$(prompt_valid "Location name: " "validate_location_name" "2-18 chars, start with letter")
        LOCATION_ID=$(prompt_valid "Location ID (100-254): " "validate_location_id" "Must be 100-254")
    fi

    # Validate inputs
    if ! validate_location_name "$LOCATION_NAME"; then
        die "Invalid location name: $LOCATION_NAME" 1
    fi
    if ! validate_location_id "$LOCATION_ID"; then
        die "Invalid location ID: $LOCATION_ID" 1
    fi

    # Derived values
    ROUTER_NAME="${LOCATION_NAME}-${LOCATION_ID}"
    GATEWAY_IP="192.168.${LOCATION_ID}.1"
    TUNNEL_PORT="2${LOCATION_ID}"
    NETWORK_CHANGED="no"

    # Summary
    printf "\n${YELLOW}=== Configuration Summary ===${NC}\n"
    printf "Router Name:   ${GREEN}%s${NC}\n" "$ROUTER_NAME"
    printf "Gateway IP:    ${GREEN}%s${NC}\n" "$GATEWAY_IP"
    printf "Tunnel Port:   ${GREEN}%s${NC}\n" "$TUNNEL_PORT"
    printf "VPS:           ${GREEN}%s@%s:%s${NC}\n" "$VPS_USER" "$VPS_IP" "$VPS_SSH_PORT"
    printf "NextDNS ID:    ${GREEN}%s${NC}\n" "$NEXTDNS_ID"
    printf "\n"

    log "INFO" "Configuration: $ROUTER_NAME, $GATEWAY_IP, tunnel=$TUNNEL_PORT"

    # Confirm
    if [ "$AUTO_MODE" != "yes" ]; then
        prompt_yes_no "Proceed with setup? (Y/n): " "y" || exit 0
    fi

    # Run setup phases
    preflight_checks || exit 1
    configure_tailscale || exit 2
    configure_ssh_tunnel || exit 3
    configure_network || exit 4
    configure_persistence
    create_deployment_record

    # Final summary
    printf "\n${GREEN}════════════════════════════════════════════════════════════════${NC}\n"
    printf "${GREEN}       Setup Complete: %s${NC}\n" "$ROUTER_NAME"
    printf "${GREEN}════════════════════════════════════════════════════════════════${NC}\n\n"

    printf "${BLUE}Access Methods:${NC}\n"
    printf "  Tailscale:  ${GREEN}ssh root@%s${NC}\n" "$ROUTER_NAME"
    printf "  Local:      ${GREEN}ssh root@%s${NC}\n" "$GATEWAY_IP"
    [ "$SKIP_SSH_TUNNEL" != "yes" ] && \
    printf "  Backup:     ${GREEN}ssh -J %s@%s root@localhost -p %s${NC}\n" "$VPS_USER" "$VPS_IP" "$TUNNEL_PORT"
    printf "\n"
    printf "Log file: ${CYAN}%s${NC}\n\n" "$LOG_FILE"

    # Handle reboot
    if [ "$NETWORK_CHANGED" = "yes" ]; then
        printf "${YELLOW}⚠️  REBOOT REQUIRED${NC}\n"
        printf "After reboot, router will be at: ${GREEN}http://%s${NC}\n\n" "$GATEWAY_IP"

        if [ "$AUTO_MODE" = "yes" ]; then
            printf "${YELLOW}Auto mode: Rebooting in 10 seconds...${NC}\n"
            log "INFO" "Auto-rebooting in 10 seconds"
            sleep 10
            reboot
        else
            prompt_yes_no "Reboot now? (Y/n): " "y" && reboot
        fi
    else
        printf "${GREEN}No reboot required - all changes are active${NC}\n"
    fi

    log "INFO" "Setup completed successfully"
}

# Run
main "$@"

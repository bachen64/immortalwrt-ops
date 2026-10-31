#!/bin/sh
# ============================================================================
# wg0 interface manager v2.4 (POSIX-compatible)
# Run every 5 min: detect DDNS change of wg0 peer, manage WG interface
# If wg0 connects to a local address, try to fix it
# ============================================================================

# ============================================================================
# Config parameters
# ============================================================================
DDNS_DOMAIN="kcn01.dynv6.net"
WG_INTERFACE="wg0"
IP_FILE="/var/run/office_last_ip.txt"
LOG_TAG="wg0-iface-manager"
LOCK_FILE="/var/run/wg_ddns.lock"
LOG_FILE="/tmp/wg_ddns.log"

# Connection check parameters
CONNECT_CHECK_TIMEOUT=5
RECONNECT_WAIT_TIME=10
DNS_RESOLVE_TIMEOUT=3

# Retry mechanism parameters
MAX_RETRY_ATTEMPTS=2
RETRY_BASE_DELAY=5
RETRY_MAX_DELAY=30

# wg0 specific parameters
WG_RESTART_DELAY=3
NETWORK_STABILIZE_DELAY=5

# Log level control
LOG_LEVEL="INFO"
DEBUG_MODE=0

# ============================================================================
# Logging system - POSIX-compatible
# ============================================================================

# Map log level name to number
get_log_level_num() {
    case "$LOG_LEVEL" in
        DEBUG|debug) echo 0 ;;
        INFO|info) echo 1 ;;
        WARNING|warning) echo 2 ;;
        ERROR|error) echo 3 ;;
        *) echo 1 ;;
    esac
}

# Internal log function
log_internal() {
    level="$1"
    message="$2"
    log_message="$level - $message"
    
    logger -t "$LOG_TAG" "$log_message"
    echo "$log_message" >> "$LOG_FILE"
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "$log_message" >&2
    fi
}

log_debug() {
    if [ $(get_log_level_num) -le 0 ]; then
        log_internal "DEBUG" "$1"
    fi
}

log_info() {
    if [ $(get_log_level_num) -le 1 ]; then
        log_internal "INFO" "$1"
    fi
}

log_warning() {
    if [ $(get_log_level_num) -le 2 ]; then
        log_internal "WARNING" "$1"
    fi
}

log_error() {
    if [ $(get_log_level_num) -le 3 ]; then
        log_internal "ERROR" "$1"
    fi
}

log_status() {
    status="$1"
    message="$2"
    
    case "$status" in
        SUCCESS) emoji="[OK]" ;;
        WARNING) emoji="[WARN]" ;;
        ERROR)   emoji="[ERR]" ;;
        INFO)    emoji="[INFO]" ;;
        *)       emoji="[*]" ;;
    esac
    
    log_info "$emoji $message"
}

# ============================================================================
# Initial requirement checks
# ============================================================================
check_requirements() {
    required_commands="wg nslookup logger flock ip ifdown ifup"
    
    for cmd in $required_commands; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Missing required command: $cmd"
            return 1
        fi
    done
    
    return 0
}

# ============================================================================
# Process lock management - POSIX-compatible
# ============================================================================
setup_lock() {
    # Check flock availability
    if ! command -v flock >/dev/null 2>&1; then
        log_warning "flock unavailable, skip lock check"
        return 0
    fi
    
    # Try to acquire lock, non-blocking
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_warning "Another instance is running, exit"
        exit 0
    fi
}

cleanup() {
    # Release lock
    if [ -n "$LOCK_FILE" ] && [ -e "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE" 2>/dev/null
    fi
    log_debug "Cleanup lock and resources"
}
trap cleanup EXIT INT TERM

# ============================================================================
# Network diagnostics - POSIX-compatible
# ============================================================================
check_dns_resolution() {
    domain="$1"
    ip_type="$2"
    
    log_debug "Check DNS: domain=$domain, type=$ip_type"
    
    result=""
    if [ "$ip_type" = "AAAA" ]; then
        result=$(nslookup -type=AAAA "$domain" 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}')
    else
        result=$(nslookup -type=A "$domain" 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}')
    fi
    
    if [ -n "$result" ]; then
        log_debug "DNS resolved: $domain -> $result"
        echo "$result"
        return 0
    else
        log_warning "DNS resolve failed: $domain (type: $ip_type)"
        return 1
    fi
}

resolve_domain_ip() {
    domain="$1"
    domain_ip=""
    
    domain_ip=$(check_dns_resolution "$domain" "AAAA")
    
    if [ -z "$domain_ip" ]; then
        log_debug "IPv6 resolve failed, try IPv4"
        domain_ip=$(check_dns_resolution "$domain" "A")
    fi
    
    if [ -n "$domain_ip" ]; then
        echo "$domain_ip"
        return 0
    else
        log_error "Cannot resolve domain: $domain"
        return 1
    fi
}

is_local_address() {
    ip="$1"
    
    # Check IPv4 local addresses
    case "$ip" in
        127.*|localhost) return 0 ;;
        10.*|172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*|192.168.*) return 0 ;;
    esac
    
    # Check IPv6 local addresses
    case "$ip" in
        ::1|0:0:0:0:0:0:0:1|fe80:*) return 0 ;;
    esac
    
    return 1
}

# wg0 status check - POSIX-compatible
get_current_peer_ip() {
    # Method 1: parse full 'wg show' output
    wg_output=$(wg show "$WG_INTERFACE" 2>/dev/null)
    
    if [ -n "$wg_output" ]; then
        # Find endpoint line
        endpoint_line=$(echo "$wg_output" | grep "^[[:space:]]*endpoint:")
        
        if [ -n "$endpoint_line" ]; then
            # Strip spaces and 'endpoint:' prefix
            endpoint_line=$(echo "$endpoint_line" | sed 's/^[[:space:]]*endpoint:[[:space:]]*//')
            
            # Extract IPv6 address (format: [ip]:port)
            if echo "$endpoint_line" | grep -q "\[.*\]:[0-9][0-9]*"; then
                echo "$endpoint_line" | sed 's/\[\(.*\)\]:[0-9][0-9]*/\1/'
                return 0
            # Extract IPv4 address (format: ip:port)
            elif echo "$endpoint_line" | grep -q "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*:[0-9][0-9]*"; then
                echo "$endpoint_line" | sed 's/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\):[0-9][0-9]*/\1/'
                return 0
            fi
        fi
    fi
    
    # Method 2: parse compact 'wg show endpoints' output
    endpoints_output=$(wg show "$WG_INTERFACE" endpoints 2>/dev/null)
    
    if [ -n "$endpoints_output" ]; then
        # Match IPv6 address (format: [ip]:port)
        if echo "$endpoints_output" | grep -q "\[.*\]:[0-9][0-9]*"; then
            echo "$endpoints_output" | sed 's/.*\[\(.*\)\]:[0-9][0-9]*.*/\1/'
            return 0
        # Match IPv4 address (format: ip:port)
        elif echo "$endpoints_output" | grep -q "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*:[0-9][0-9]*"; then
            echo "$endpoints_output" | sed 's/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\):[0-9][0-9]*.*/\1/'
            return 0
        fi
    fi
    
    # Nothing found, return empty
    echo ""
    return 1
}

# wg0 connection state check
check_wg_connection() {
    current_ip=$(get_current_peer_ip)
    
    if [ -z "$current_ip" ]; then
        log_debug "$WG_INTERFACE not connected or no peer IP"
        echo "DISCONNECTED"
        return 2
    elif is_local_address "$current_ip"; then
        log_warning "$WG_INTERFACE connected to a local address: $current_ip"
        echo "LOCAL_CONNECTION"
        return 1
    else
        log_debug "$WG_INTERFACE connected OK to: $current_ip"
        echo "CONNECTED"
        return 0
    fi
}

# Check wg0 interface exists and has an IP
check_wg_interface_health() {
    # 1. Interface exists
    if ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        log_debug "$WG_INTERFACE interface missing"
        echo "INTERFACE_MISSING"
        return 1
    fi
    
    # 2. Interface has an IP address
    if ! ip addr show "$WG_INTERFACE" 2>/dev/null | grep -q "inet "; then
        log_debug "$WG_INTERFACE has no IP address"
        echo "NO_IP_ADDRESS"
        return 2
    fi
    
    # 3. Check wg0 tunnel state
    if ! wg show "$WG_INTERFACE" >/dev/null 2>&1; then
        log_debug "$WG_INTERFACE config may be broken"
        echo "WG_CONFIG_ERROR"
        return 3
    fi
    
    echo "HEALTHY"
    return 0
}

# ============================================================================
# wg0 management functions
# ============================================================================
restart_wg0() {
    attempt=1
    max_attempts=2
    result=1
    
    while [ $attempt -le $max_attempts ] && [ $result -ne 0 ]; do
        log_status "INFO" "Restarting $WG_INTERFACE (attempt $attempt/$max_attempts)"
        
        if ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
            log_error "$WG_INTERFACE interface missing"
            return 1
        fi
        
        log_debug "Bring down $WG_INTERFACE"
        if ifdown "$WG_INTERFACE" 2>/dev/null; then
            log_debug "$WG_INTERFACE is down"
            sleep "$WG_RESTART_DELAY"
        else
            log_warning "ifdown failed, try alternative"
            ip link set dev "$WG_INTERFACE" down
            sleep 2
        fi
        
        log_debug "Wait for network to stabilize..."
        sleep "$NETWORK_STABILIZE_DELAY"
        
        log_debug "Bring up $WG_INTERFACE"
        if ifup "$WG_INTERFACE" 2>/dev/null; then
            log_debug "$WG_INTERFACE is up"
            
            log_debug "Wait for $WG_INTERFACE connection..."
            sleep "$RECONNECT_WAIT_TIME"
            
            connection_state=$(check_wg_connection)
            if [ "$connection_state" = "CONNECTED" ]; then
                new_ip=$(get_current_peer_ip)
                log_status "SUCCESS" "$WG_INTERFACE restarted, new peer IP: $new_ip"
                result=0
            else
                log_warning "$WG_INTERFACE state after restart: $connection_state"
                result=1
            fi
        else
            log_error "ifup failed, try alternative"
            ip link set dev "$WG_INTERFACE" up
            sleep 3
            
            interface_health=$(check_wg_interface_health)
            if [ "$interface_health" = "HEALTHY" ] || [ "$interface_health" = "NO_IP_ADDRESS" ]; then
                sleep "$RECONNECT_WAIT_TIME"
                connection_state=$(check_wg_connection)
                if [ "$connection_state" = "CONNECTED" ]; then
                    new_ip=$(get_current_peer_ip)
                    log_status "SUCCESS" "$WG_INTERFACE up via alternative method"
                    result=0
                else
                    log_warning "$WG_INTERFACE up but state: $connection_state"
                    result=1
                fi
            else
                log_error "Cannot bring up $WG_INTERFACE (health: $interface_health)"
                result=1
            fi
        fi
        
        if [ $result -ne 0 ]; then
            delay=$((RETRY_BASE_DELAY * attempt))
            if [ $delay -gt $RETRY_MAX_DELAY ]; then
                delay=$RETRY_MAX_DELAY
            fi
            log_debug "$WG_INTERFACE restart failed, retry in ${delay}s"
            sleep $delay
        fi
        
        attempt=$((attempt + 1))
    done
    
    return $result
}

fix_local_connection() {
    log_status "WARNING" "$WG_INTERFACE connected to a local address, try to fix"
    
    current_ip=$(get_current_peer_ip)
    log_debug "Current bad state: connected to $current_ip"
    
    if restart_wg0; then
        log_status "SUCCESS" "local-connection issue fixed"
        return 0
    else
        log_error "failed to fix local-connection issue"
        return 1
    fi
}

# ============================================================================
# DDNS monitoring
# ============================================================================
read_last_ip() {
    if [ -f "$IP_FILE" ]; then
        cat "$IP_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

save_current_ip() {
    ip="$1"
    echo "$ip" > "$IP_FILE"
    log_debug "Saved IP record: $ip -> $IP_FILE"
}

handle_ip_change() {
    old_ip="$1"
    new_ip="$2"
    
    log_status "INFO" "Peer IP changed: $old_ip -> $new_ip"
    save_current_ip "$new_ip"
    
    if restart_wg0; then
        log_status "SUCCESS" "$WG_INTERFACE peer updated to new IP: $new_ip"
        return 0
    else
        log_error "failed to update peer IP"
        return 1
    fi
}

monitor_ddns() {
    log_status "INFO" "Start DDNS monitor check"
    
    domain_ip=$(resolve_domain_ip "$DDNS_DOMAIN")
    if [ -z "$domain_ip" ]; then
        log_error "Peer DDNS resolve failed, skip this run"
        return 1
    fi
    
    current_ip=$(get_current_peer_ip)
    last_ip=$(read_last_ip)
    
    # Handle empty display values
    if [ -z "$current_ip" ]; then
        current_display="(none)"
    else
        current_display="$current_ip"
    fi
    
    if [ -z "$last_ip" ]; then
        last_display="(none)"
    else
        last_display="$last_ip"
    fi
    
    log_info "DDNS check: resolved=$domain_ip, connected=$current_display, last=$last_display"
    
    connection_state=$(check_wg_connection)
    if [ "$connection_state" = "LOCAL_CONNECTION" ]; then
        fix_local_connection
        current_ip=$(get_current_peer_ip)
    fi
    
    if [ -z "$last_ip" ]; then
        log_status "INFO" "First run, record initial peer IP: $domain_ip"
        save_current_ip "$domain_ip"
    elif [ "$domain_ip" != "$last_ip" ]; then
        handle_ip_change "$last_ip" "$domain_ip"
    else
        log_debug "Peer IP unchanged, nothing to do"
    fi
    
    return 0
}

# ============================================================================
# Optimized health check
# ============================================================================
perform_health_check() {
    log_status "INFO" "Run $WG_INTERFACE health check"
    
    # 1. Peer connection state
    connection_state=$(check_wg_connection)
    
    # 2. Interface health
    interface_health=$(check_wg_interface_health)
    
    # 3. DNS resolution
    dns_status="FAIL"
    if resolve_domain_ip "$DDNS_DOMAIN" >/dev/null; then
        dns_status="OK"
    fi
    
    # 4. Detailed wg0 status
    endpoint_info=""
    handshake_info=""
    transfer_info=""
    
    wg_output=$(wg show "$WG_INTERFACE" 2>/dev/null)
    
    if [ -n "$wg_output" ]; then
        # Extract endpoint info
        endpoint_info=$(echo "$wg_output" | grep "^[[:space:]]*endpoint:" | head -1 | sed 's/^[[:space:]]*endpoint:[[:space:]]*//')
        
        # Extract latest handshake
        handshake_info=$(echo "$wg_output" | grep "^[[:space:]]*latest handshake:" | head -1 | sed 's/^[[:space:]]*latest handshake:[[:space:]]*//')
        
        # Extract transfer stats
        transfer_info=$(echo "$wg_output" | grep "^[[:space:]]*transfer:" | head -1 | sed 's/^[[:space:]]*transfer:[[:space:]]*//')
    fi
    
    # Output health check report
    log_info "Health check report:"
    log_info "  - $WG_INTERFACE peer connection: $connection_state"
    log_info "  - $WG_INTERFACE interface health: $interface_health"
    log_info "  - $WG_INTERFACE peer DNS resolution: $dns_status"
    
    if [ -n "$endpoint_info" ]; then
        log_info "  - endpoint: $endpoint_info"
    fi
    
    if [ -n "$handshake_info" ]; then
        log_info "  - latest handshake: $handshake_info"
    fi
    
    if [ -n "$transfer_info" ]; then
        log_info "  - transfer: $transfer_info"
    fi
    
    # Decide result by connection state
    case "$connection_state" in
        CONNECTED)
            # Even if connected, check interface health
            case "$interface_health" in
                HEALTHY)
                    log_status "SUCCESS" "health check passed: $WG_INTERFACE fully OK"
                    return 0
                    ;;
                NO_IP_ADDRESS)
                    log_status "WARNING" "warning: $WG_INTERFACE connected but interface missing IP"
                    return 1
                    ;;
                *)
                    log_status "WARNING" "warning: $WG_INTERFACE connected but state: $interface_health"
                    return 1
                    ;;
            esac
            ;;
        LOCAL_CONNECTION)
            log_status "WARNING" "warning: $WG_INTERFACE connected to a local address"
            return 2
            ;;
        DISCONNECTED)
            log_status "ERROR" "health check failed: $WG_INTERFACE not connected"
            return 3
            ;;
        *)
            log_status "ERROR" "health check failed: unknown state"
            return 4
            ;;
    esac
}

# ============================================================================
# Command line interface
# ============================================================================
show_usage() {
    cat << EOF
$WG_INTERFACE interface manager

Usage: $0 [options]

Options:
  --check         run health check only, no fix
  --debug         enable debug mode
  --force         force run even if another instance runs
  --help          show this help
  --version       show version

Examples:
  $0              run DDNS monitor and fix
  $0 --check      check only, no fix
  $0 --debug      verbose logs

EOF
}

show_version() {
    echo "wg0 interface manager v2.4 (POSIX-compatible)"
}

# ============================================================================
# Main
# ============================================================================
main() {
    mode="MONITOR"
    force_run=0
    
    # Acquire lock
    setup_lock
    
    while [ $# -gt 0 ]; do
        case $1 in
            --check)
                mode="CHECK"
                shift
                ;;
            --debug)
                DEBUG_MODE=1
                LOG_LEVEL="DEBUG"
                shift
                ;;
            --force)
                force_run=1
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    log_info "Script started, mode: $mode"
    log_debug "Runtime params: LOG_LEVEL=$LOG_LEVEL, DEBUG_MODE=$DEBUG_MODE"
    
    if ! check_requirements; then
        log_error "System requirement check failed"
        exit 1
    fi
    
    case "$mode" in
        CHECK)
            perform_health_check
            health_status=$?
            exit $health_status
            ;;
        MONITOR)
            if monitor_ddns; then
                log_status "SUCCESS" "DDNS monitor done"
                # Run health check silently, log errors only
                if ! perform_health_check >/dev/null 2>&1; then
                    log_warning "Health check failed but DDNS monitor done"
                fi
                exit 0
            else
                log_error "DDNS monitor error"
                exit 1
            fi
            ;;
    esac
}

main "$@"

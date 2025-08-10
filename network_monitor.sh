#!/bin/bash

# Set log file location based on user privileges
if [ "$(id -u)" -eq 0 ]; then
    LOGFILE="/var/log/network_startup_monitor.log"
    LOCKFILE="/var/run/network_monitor.lock"
else
    # Non-root user - use home directory or temp location
    if [ -n "$HOME" ] && [ -w "$HOME" ]; then
        LOGFILE="$HOME/network_startup_monitor.log"
        LOCKFILE="$HOME/network_monitor.lock"
    else
        LOGFILE="/tmp/network_startup_monitor_$(id -u).log"
        LOCKFILE="/tmp/network_monitor_$(id -u).lock"
    fi
fi
SLEEP_INTERVAL=1
TOTAL_TIMEOUT=900
RUN_AFTER_SUCCESS=60
PING_TIMEOUT=1
BLOCKING_MODE=false
INTERFACE_TYPES="ethernet bond"
REQUIRED_INTERFACES=""  # Space-separated list of specific interfaces that must be up (empty = any interface sufficient)
NETWORK_SERVICES="systemd-networkd.service systemd-networkd-wait-online.service NetworkManager.service NetworkManager-wait-online.service systemd-resolved.service networking.service dhcpcd.service wpa_supplicant.service"
RESOLVER_HOSTNAME="google.com"
DNS_TIMEOUT=1

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --blocking)
            BLOCKING_MODE=true
            RUN_AFTER_SUCCESS=0
            shift
            ;;
        --required-interfaces)
            if [ -z "$2" ]; then
                echo "Error: --required-interfaces requires a space-separated list of interface names"
                exit 1
            fi
            REQUIRED_INTERFACES="$2"
            shift 2
            ;;
        --total-timeout)
            if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --total-timeout requires a positive integer (seconds)"
                exit 1
            fi
            TOTAL_TIMEOUT="$2"
            shift 2
            ;;
        --run-after-success)
            if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --run-after-success requires a positive integer (seconds)"
                exit 1
            fi
            RUN_AFTER_SUCCESS="$2"
            shift 2
            ;;
        --sleep-interval)
            if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                echo "Error: --sleep-interval requires a positive number (seconds, fractional allowed)"
                exit 1
            fi
            SLEEP_INTERVAL="$2"
            shift 2
            ;;
        --ping-timeout)
            if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --ping-timeout requires a positive integer (seconds)"
                exit 1
            fi
            PING_TIMEOUT="$2"
            shift 2
            ;;
        --dns-timeout)
            if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --dns-timeout requires a positive integer (seconds)"
                exit 1
            fi
            DNS_TIMEOUT="$2"
            shift 2
            ;;
        --interface-types)
            if [ -z "$2" ]; then
                echo "Error: --interface-types requires a space-separated list of types"
                exit 1
            fi
            INTERFACE_TYPES="$2"
            shift 2
            ;;
        --network-services)
            if [ -z "$2" ]; then
                echo "Error: --network-services requires a space-separated list of service names"
                exit 1
            fi
            NETWORK_SERVICES="$2"
            shift 2
            ;;
        --resolver-hostname)
            if [ -z "$2" ]; then
                echo "Error: --resolver-hostname requires a hostname"
                exit 1
            fi
            RESOLVER_HOSTNAME="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Network startup monitor service for Linux systems"
            echo ""
            echo "OPTIONS:"
            echo "  --blocking                      Exit immediately when network is ready (default: continuous monitoring)"
            echo "  --required-interfaces \"list\"    Space-separated interfaces that must be up (default: any interface sufficient)"
            echo "  --total-timeout SECONDS        Maximum runtime in seconds (default: 900)"
            echo "  --run-after-success SECONDS    Time to run after network ready in monitoring mode (default: 60)"
            echo "  --sleep-interval SECONDS       Check frequency in seconds, fractional allowed (default: 1)"
            echo "  --ping-timeout SECONDS         Gateway ping timeout in seconds (default: 1)"
            echo "  --dns-timeout SECONDS          DNS resolution timeout in seconds (default: 1)"
            echo "  --interface-types \"list\"       Space-separated interface types to monitor (default: \"ethernet bond\")"
            echo "  --network-services \"list\"      Space-separated network services to monitor"
            echo "  --resolver-hostname HOSTNAME   Hostname for DNS resolution test (default: google.com)"
            echo "  --help, -h                      Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                                           # Monitor any interface, continuous mode"
            echo "  $0 --blocking                                # Exit when network ready"
            echo "  $0 --required-interfaces \"eth0 eth1\"        # Require specific interfaces"
            echo "  $0 --total-timeout 300 --sleep-interval 1.5 # Custom timeouts with fractional sleep"
            echo "  $0 --interface-types \"ethernet bond vlan\"   # Monitor additional interface types"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

rotate_log_file() {
    local max_size_mb=10
    local max_archives=5
    
    # Check if log file exists and get size
    if [ ! -f "$LOGFILE" ]; then
        return 0
    fi
    
    # Get file size in MB
    local file_size_mb=$(du -m "$LOGFILE" 2>/dev/null | cut -f1)
    if [ -z "$file_size_mb" ] || [ "$file_size_mb" -lt "$max_size_mb" ]; then
        return 0
    fi
    
    # Rotate logs
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local archived_log="${LOGFILE}.${timestamp}"
    
    # Move current log to archive
    mv "$LOGFILE" "$archived_log"
    
    # Create new empty log file
    touch "$LOGFILE"
    chmod 644 "$LOGFILE"
    
    # Log rotation message to new file
    echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') - Log rotated: $archived_log (${file_size_mb}MB)" >> "$LOGFILE"
    
    # Clean up old archives - keep only the last N files
    local log_dir=$(dirname "$LOGFILE")
    local log_basename=$(basename "$LOGFILE")
    
    # Find archived logs and remove old ones
    find "$log_dir" -name "${log_basename}.*" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort -rn | \
        tail -n +$((max_archives + 1)) | \
        cut -d' ' -f2- | \
        while read -r old_archive; do
            rm -f "$old_archive"
            echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') - Removed old archive: $old_archive" >> "$LOGFILE"
        done
}

# Log rotation check counter - only check every N log messages
LOG_MESSAGE_COUNT=0

log_message() {
    # Only check for log rotation every 10 messages to reduce overhead
    LOG_MESSAGE_COUNT=$((LOG_MESSAGE_COUNT + 1))
    if [ $((LOG_MESSAGE_COUNT % 10)) -eq 0 ]; then
        rotate_log_file
    fi
    
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S.%3N') - $1"
    echo "$timestamp"
    
    # Try to append to logfile, but suppress read-only filesystem errors during boot
    if ! echo "$timestamp" >> "$LOGFILE" 2>/dev/null; then
        # Silently continue if we can't write to log file (e.g., during early boot)
        true
    fi
}

cleanup() {
    log_message "Network monitor shutting down"
    rm -f "$LOCKFILE"
    exit 0
}

trap cleanup SIGTERM SIGINT

if [ -f "$LOCKFILE" ]; then
    log_message "Network monitor already running (lockfile exists)"
    exit 1
fi

echo $$ > "$LOCKFILE"

# Startup banner
log_message "============================================================="
log_message "    NETWORK STARTUP MONITOR SERVICE - $(date)"
log_message "============================================================="
log_message "PID: $$"
log_message "Mode: $([ "$BLOCKING_MODE" = true ] && echo "BLOCKING" || echo "MONITORING")"
log_message "Timeouts: Total=${TOTAL_TIMEOUT}s, AfterSuccess=${RUN_AFTER_SUCCESS}s, Sleep=${SLEEP_INTERVAL}s"
log_message "Interface Types: $INTERFACE_TYPES"
if [ -n "$REQUIRED_INTERFACES" ]; then
    log_message "Required Interfaces: $REQUIRED_INTERFACES (all must be up)"
else
    log_message "Required Interfaces: Any interface sufficient"
fi
log_message "DNS Resolver: $RESOLVER_HOSTNAME (timeout: ${DNS_TIMEOUT}s)"
log_message "Ping Timeout: ${PING_TIMEOUT}s"
log_message "============================================================="

if [ "$BLOCKING_MODE" = true ]; then
    log_message "Network wait service starting (BLOCKING MODE - timeout: ${TOTAL_TIMEOUT}s)"
else
    log_message "Network monitor starting up (timeout: ${TOTAL_TIMEOUT}s, run-after-success: ${RUN_AFTER_SUCCESS}s)"
fi

START_TIME=$(date +%s)

# Cache service information at startup to avoid repeated systemctl calls
log_message "Caching network service information..."
AVAILABLE_SERVICES=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1 ":" $2}')
ENABLED_SERVICES=""
for service in $NETWORK_SERVICES; do
    service_info=$(echo "$AVAILABLE_SERVICES" | grep "^$service:")
    if [ -n "$service_info" ]; then
        service_state=$(echo "$service_info" | cut -d':' -f2)
        case "$service_state" in
            "enabled"|"enabled-runtime"|"static"|"generated"|"indirect")
                ENABLED_SERVICES="$ENABLED_SERVICES $service"
                log_message "Service $service: found and enabled/static - will monitor"
                ;;
            "disabled")
                log_message "Service $service: found but disabled - skipping"
                ;;
            *)
                log_message "Service $service: found with state '$service_state' - skipping"
                ;;
        esac
    else
        log_message "Service $service: not found - skipping"
    fi
done

check_interface_status() {
    local interface="$1"
    local carrier_file="/sys/class/net/$interface/carrier"
    local operstate_file="/sys/class/net/$interface/operstate"
    
    if [ -f "$carrier_file" ]; then
        # Optimized: combine both file reads with compound redirection
        {
            read -r carrier < "$carrier_file" 2>/dev/null || carrier="unknown"
            read -r operstate < "$operstate_file" 2>/dev/null || operstate="unknown"
        }
        
        case "$carrier" in
            "1") carrier_status="UP" ;;
            "0") carrier_status="DOWN" ;;
            *) carrier_status="UNKNOWN" ;;
        esac
        
        log_message "Interface $interface: carrier=$carrier_status, operstate=$operstate"
        
        # Return carrier status for caller (1 if up, 0 if down/unknown)
        [ "$carrier" = "1" ]
    else
        log_message "Interface $interface: not found or not accessible"
        return 1
    fi
}

get_default_gateway() {
    ip route | grep '^default' | awk '{print $3}' | head -n1
}

check_gateway_reachability() {
    local gateway="$1"
    if [ -n "$gateway" ]; then
        if ping -c 1 -W "$PING_TIMEOUT" "$gateway" >/dev/null 2>&1; then
            log_message "Gateway $gateway: REACHABLE (${PING_TIMEOUT}s timeout)"
            return 0
        else
            log_message "Gateway $gateway: UNREACHABLE (${PING_TIMEOUT}s timeout)"
            return 1
        fi
    else
        log_message "Gateway: NOT CONFIGURED"
        return 1
    fi
}

check_hostname_resolution() {
    local hostname="$1"
    if [ -z "$hostname" ]; then
        log_message "DNS resolution: NO HOSTNAME CONFIGURED"
        return 1
    fi
    
    # Try nslookup with timeout
    if timeout "${DNS_TIMEOUT}s" nslookup "$hostname" >/dev/null 2>&1; then
        log_message "DNS resolution for $hostname: SUCCESS"
        return 0
    # Try host command with timeout
    elif timeout "${DNS_TIMEOUT}s" host "$hostname" >/dev/null 2>&1; then
        log_message "DNS resolution for $hostname: SUCCESS (via host)"
        return 0
    # Try getent with timeout (getent doesn't have built-in timeout)
    elif timeout "${DNS_TIMEOUT}s" getent hosts "$hostname" >/dev/null 2>&1; then
        log_message "DNS resolution for $hostname: SUCCESS (via getent)"
        return 0
    else
        log_message "DNS resolution for $hostname: FAILED (${DNS_TIMEOUT}s timeout)"
        return 1
    fi
}

check_arp_table() {
    log_message "--- ARP Table Status ---"
    
    # Get all active interfaces
    local interfaces
    interfaces=$(get_active_interfaces)
    
    if [ -z "$interfaces" ]; then
        log_message "ARP table: No interfaces to check"
        return 1
    fi
    
    local total_arp_entries=0
    local gateway_arp_found=false
    local gateway_ip
    gateway_ip=$(get_default_gateway)
    
    # Check ARP entries per interface
    for interface in $interfaces; do
        local arp_count=0
        local interface_entries=""
        
        # Optimized: Get ARP entries with single-pass processing
        if command -v ip >/dev/null 2>&1; then
            local interface_entries gateway_mac=""
            interface_entries=$(ip neighbor show dev "$interface" 2>/dev/null)
            
            if [ -n "$interface_entries" ]; then
                # Single-pass processing of ARP entries
                {
                    arp_count=0
                    while IFS= read -r arp_line; do
                        # Skip failed/incomplete entries
                        case "$arp_line" in
                            *"FAILED"*|*"INCOMPLETE"*) continue ;;
                        esac
                        
                        if [ -n "$arp_line" ]; then
                            ((arp_count++))
                            
                            # Check for gateway in same pass
                            if [ -n "$gateway_ip" ] && [[ "$arp_line" =~ ^"$gateway_ip " ]]; then
                                gateway_arp_found=true
                                gateway_mac=$(echo "$arp_line" | awk '{print $3}')
                            fi
                        fi
                    done
                } <<< "$interface_entries"
                
                total_arp_entries=$((total_arp_entries + arp_count))
                
                # Log results
                if [ -n "$gateway_ip" ] && [ "$gateway_arp_found" = true ] && [ -n "$gateway_mac" ]; then
                    log_message "ARP table $interface: $arp_count entries (gateway $gateway_ip -> $gateway_mac)"
                elif [ -n "$gateway_ip" ]; then
                    log_message "ARP table $interface: $arp_count entries (no gateway entry)"
                else
                    log_message "ARP table $interface: $arp_count entries"
                fi
            else
                log_message "ARP table $interface: 0 entries"
            fi
        else
            log_message "ARP table $interface: ip command not available"
        fi
    done
    
    log_message "ARP table total: $total_arp_entries entries"
    
    if [ -n "$gateway_ip" ]; then
        if [ "$gateway_arp_found" = true ]; then
            log_message "ARP table gateway: $gateway_ip RESOLVED"
            return 0
        else
            log_message "ARP table gateway: $gateway_ip NOT RESOLVED"
            return 1
        fi
    else
        # If no gateway, consider ARP table valid if we have any entries
        if [ $total_arp_entries -gt 0 ]; then
            log_message "ARP table: POPULATED (no gateway to check)"
            return 0
        else
            log_message "ARP table: EMPTY"
            return 1
        fi
    fi
}

check_routing_table() {
    log_message "--- Routing Table Status ---"
    
    local total_routes=0
    local default_routes=0
    local interface_routes=0
    local host_routes=0
    local network_routes=0
    
    if command -v ip >/dev/null 2>&1; then
        # Get routing table information
        local route_output
        route_output=$(ip route show 2>/dev/null)
        
        if [ -n "$route_output" ]; then
            # Optimized: Single-pass processing instead of multiple grep operations
            {
                total_routes=0
                default_routes=0
                interface_routes=0
                host_routes=0
                network_routes=0
                
                while IFS= read -r route_line; do
                    if [ -n "$route_line" ]; then
                        ((total_routes++))
                        
                        # Check route type in single pass
                        case "$route_line" in
                            "default "*)
                                ((default_routes++))
                                ;;
                        esac
                        
                        # Check for interface routes
                        [[ "$route_line" =~ " dev " ]] && ((interface_routes++))
                        
                        # Check for host routes
                        if [[ "$route_line" =~ "/32 " ]]; then
                            ((host_routes++))
                        elif [[ "$route_line" =~ /[0-9]+\  ]]; then
                            ((network_routes++))
                        fi
                    fi
                done
            } <<< "$route_output"
            
            log_message "Routing table: $total_routes total routes"
            log_message "Routing table: $default_routes default routes"
            log_message "Routing table: $network_routes network routes"
            log_message "Routing table: $host_routes host routes"
            
            # Check for default route details
            if [ $default_routes -gt 0 ]; then
                local default_route_info
                default_route_info=$(echo "$route_output" | grep "^default ")
                while IFS= read -r route_line; do
                    if [ -n "$route_line" ]; then
                        local gateway_ip=""
                        local interface=""
                        local metric=""
                        
                        # Parse route line for gateway, interface, and metric
                        gateway_ip=$(echo "$route_line" | grep -o 'via [0-9.]*' | cut -d' ' -f2)
                        interface=$(echo "$route_line" | grep -o 'dev [a-zA-Z0-9]*' | cut -d' ' -f2)
                        metric=$(echo "$route_line" | grep -o 'metric [0-9]*' | cut -d' ' -f2)
                        
                        if [ -n "$metric" ]; then
                            log_message "Default route: $gateway_ip via $interface (metric $metric)"
                        else
                            log_message "Default route: $gateway_ip via $interface"
                        fi
                    fi
                done <<< "$default_route_info"
                
                return 0
            else
                log_message "Routing table: NO DEFAULT ROUTE"
                return 1
            fi
        else
            log_message "Routing table: NO ROUTES FOUND"
            return 1
        fi
    else
        # Fallback to route command if ip is not available
        if command -v route >/dev/null 2>&1; then
            local route_output
            route_output=$(route -n 2>/dev/null | tail -n +3)  # Skip header lines
            
            if [ -n "$route_output" ]; then
                total_routes=$(echo "$route_output" | wc -l)
                default_routes=$(echo "$route_output" | grep -c "^0.0.0.0 " || echo "0")
                
                log_message "Routing table: $total_routes total routes (route command)"
                log_message "Routing table: $default_routes default routes"
                
                if [ $default_routes -gt 0 ]; then
                    local default_info
                    default_info=$(echo "$route_output" | grep "^0.0.0.0 ")
                    echo "$default_info" | while IFS= read -r route_line; do
                        if [ -n "$route_line" ]; then
                            local gateway_ip
                            local interface
                            gateway_ip=$(echo "$route_line" | awk '{print $2}')
                            interface=$(echo "$route_line" | awk '{print $8}')
                            log_message "Default route: $gateway_ip via $interface"
                        fi
                    done
                    
                    return 0
                else
                    log_message "Routing table: NO DEFAULT ROUTE"
                    return 1
                fi
            else
                log_message "Routing table: NO ROUTES FOUND"
                return 1
            fi
        else
            log_message "Routing table: Neither 'ip' nor 'route' command available"
            return 1
        fi
    fi
}

check_networkmanager_connectivity() {
    # Check if NetworkManager is running first
    if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        log_message "NetworkManager connectivity: SERVICE NOT RUNNING"
        return 2  # Service not available, don't count as failure
    fi
    
    # Check if nmcli is available
    if ! command -v nmcli >/dev/null 2>&1; then
        log_message "NetworkManager connectivity: NMCLI NOT AVAILABLE"
        return 2  # Tool not available, don't count as failure
    fi
    
    local connectivity_status
    connectivity_status=$(nmcli networking connectivity 2>/dev/null)
    local nmcli_exit_code=$?
    
    if [ $nmcli_exit_code -ne 0 ]; then
        log_message "NetworkManager connectivity: QUERY FAILED"
        return 2  # Query failed, don't count as failure
    fi
    
    case "$connectivity_status" in
        "full")
            log_message "NetworkManager connectivity: FULL"
            return 0
            ;;
        "limited")
            log_message "NetworkManager connectivity: LIMITED"
            return 1
            ;;
        "portal")
            log_message "NetworkManager connectivity: PORTAL (captive portal detected)"
            return 1
            ;;
        "none")
            log_message "NetworkManager connectivity: NONE"
            return 1
            ;;
        "unknown")
            log_message "NetworkManager connectivity: UNKNOWN (check disabled or failed)"
            return 2  # Don't count as failure
            ;;
        *)
            log_message "NetworkManager connectivity: UNEXPECTED STATUS ($connectivity_status)"
            return 2  # Don't count as failure
            ;;
    esac
}

get_interface_type() {
    local interface="$1"
    local type_file="/sys/class/net/$interface/type"
    
    if [ -f "$type_file" ]; then
        local arphrd_type=$(cat "$type_file" 2>/dev/null || echo "0")
        
        # Special handling for ARPHRD_ETHER (type 1) - could be ethernet, bridge, bond, etc.
        if [ "$arphrd_type" = "1" ]; then
            # Check for bridge
            if [ -d "/sys/class/net/$interface/bridge" ]; then
                echo "bridge"
                return
            fi
            # Check for bond (handled separately but for completeness)
            if [ -d "/proc/net/bonding/$interface" ]; then
                echo "bond"
                return
            fi
            # Check for VLAN
            if [ -f "/proc/net/vlan/$interface" ]; then
                echo "vlan"
                return
            fi
            # Default to ethernet for ARPHRD_ETHER
            echo "ethernet"
        else
            case "$arphrd_type" in
                "772")  echo "loopback" ;;
                "776")  echo "tunnel" ;;
                "778")  echo "gre" ;;
                "783")  echo "irda" ;;
                "801")  echo "wireless" ;;
                *)      echo "other" ;;
            esac
        fi
    else
        echo "unknown"
    fi
}

is_interface_type_monitored() {
    local interface="$1"
    local interface_type=$(get_interface_type "$interface")
    
    # Check if this interface type should be monitored
    for monitored_type in $INTERFACE_TYPES; do
        case "$monitored_type" in
            "all")
                return 0
                ;;
            "$interface_type")
                return 0
                ;;
        esac
    done
    return 1
}

get_active_interfaces() {
    # IMPORTANT: Never cache this function's result - interface discovery
    # during boot is one of the key things we need to troubleshoot.
    # Interfaces can be created/renamed/removed during system startup,
    # especially with bond interfaces, network managers, and udev rules.
    local all_interfaces=$(ip link show | grep -E '^[0-9]+:' | grep -v 'lo:' | awk -F': ' '{print $2}' | awk '{print $1}')
    local filtered_interfaces=""
    
    for interface in $all_interfaces; do
        local interface_type=$(get_interface_type "$interface")
        if is_interface_type_monitored "$interface"; then
            filtered_interfaces="$filtered_interfaces $interface"
            if [ "$interface_type" = "bond" ]; then
                log_message "Interface discovery: $interface (type=$interface_type) - BOND INTERFACE FOUND"
            fi
        fi
    done
    
    echo "$filtered_interfaces" | xargs -n1 | sort -u | xargs
}

is_bond_interface() {
    local interface="$1"
    [ -d "/proc/net/bonding/$interface" ]
}

check_bond_status() {
    local interface="$1"
    local bond_file="/proc/net/bonding/$interface"
    
    if [ ! -f "$bond_file" ]; then
        log_message "Bond $interface: bonding file not found"
        return 1
    fi
    
    local mode=$(grep "Bonding Mode:" "$bond_file" | awk -F': ' '{print $2}')
    local mii_status=$(grep "MII Status:" "$bond_file" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
    local active_slaves=$(grep "Currently Active Slave:" "$bond_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local slave_count=$(grep -c "Slave Interface:" "$bond_file")
    local up_slaves=$(grep -A1 "Slave Interface:" "$bond_file" | grep "MII Status: up" | wc -l)
    
    log_message "Bond $interface: mode=$mode, mii_status=$mii_status, active_slave=$active_slaves, slaves=$up_slaves/$slave_count"
    
    if [ "$mii_status" != "up" ]; then
        log_message "Bond $interface: MII status is not up"
        return 1
    fi
    
    if [ "$up_slaves" -eq 0 ]; then
        log_message "Bond $interface: no active slaves"
        return 1
    fi
    
    case "$mode" in
        *"IEEE 802.3ad"*|*"802.3ad"*)
            if ! check_lacp_status "$interface"; then
                return 1
            fi
            ;;
        *"active-backup"*)
            if [ -z "$active_slaves" ] || [ "$active_slaves" = "None" ]; then
                log_message "Bond $interface: no active slave in active-backup mode"
                return 1
            fi
            ;;
    esac
    
    log_message "Bond $interface: HEALTHY"
    return 0
}

check_lacp_status() {
    local interface="$1"
    local bond_file="/proc/net/bonding/$interface"
    local lacp_ok=true
    
    while read -r line; do
        if echo "$line" | grep -q "Slave Interface:"; then
            slave_name=$(echo "$line" | awk -F': ' '{print $2}' | tr -d ' ')
            slave_section=true
        elif [ "$slave_section" = true ] && echo "$line" | grep -q "details actor lacp pdu:"; then
            read -r next_line
            if echo "$next_line" | grep -q "system priority:"; then
                read -r system_line
                read -r port_line
                read -r key_line
                read -r state_line
                
                if echo "$state_line" | grep -q "state: "; then
                    state=$(echo "$state_line" | awk -F'state: ' '{print $2}' | awk '{print $1}')
                    state_val=$(printf "%d" "0x$state" 2>/dev/null || echo "0")
                    
                    collecting=$((state_val & 0x10))
                    distributing=$((state_val & 0x20))
                    
                    if [ $collecting -eq 0 ] || [ $distributing -eq 0 ]; then
                        log_message "Bond $interface slave $slave_name: LACP not fully negotiated (state: $state)"
                        lacp_ok=false
                    else
                        log_message "Bond $interface slave $slave_name: LACP negotiated (state: $state)"
                    fi
                fi
            fi
            slave_section=false
        fi
    done < "$bond_file"
    
    if [ "$lacp_ok" = true ]; then
        log_message "Bond $interface: LACP negotiation complete"
        return 0
    else
        log_message "Bond $interface: LACP negotiation incomplete"
        return 1
    fi
}

check_interfaces_ready() {
    local interfaces=$(get_active_interfaces)
    local interfaces_up=0
    local interfaces_down=0
    local required_interfaces_up=0
    local required_interfaces_down=0
    
    if [ -z "$interfaces" ]; then
        log_message "No network interfaces found"
        return 1
    fi
    
    # Check all monitored interfaces
    for interface in $interfaces; do
        local interface_up=false
        
        # Check interface status
        if check_interface_status "$interface"; then
            interface_up=true
            ((interfaces_up++))
        else
            ((interfaces_down++))
        fi
        
        # Check bond status if applicable
        if is_bond_interface "$interface"; then
            log_message "Interface $interface: BOND INTERFACE DETECTED - checking bond status"
            if ! check_bond_status "$interface"; then
                log_message "Interface $interface: BOND STATUS FAILED - marking interface down"
                if [ "$interface_up" = true ]; then
                    ((interfaces_up--))
                    ((interfaces_down++))
                fi
                interface_up=false
            else
                log_message "Interface $interface: BOND STATUS OK"
            fi
        fi
        
        # Check if this is a required interface
        if [ -n "$REQUIRED_INTERFACES" ]; then
            for required_interface in $REQUIRED_INTERFACES; do
                if [ "$interface" = "$required_interface" ]; then
                    if [ "$interface_up" = true ]; then
                        ((required_interfaces_up++))
                    else
                        ((required_interfaces_down++))
                    fi
                    break
                fi
            done
        fi
    done
    
    # Determine if interfaces are ready
    if [ -n "$REQUIRED_INTERFACES" ]; then
        # Specific interfaces required - all must be up
        local total_required_interfaces=$(echo "$REQUIRED_INTERFACES" | wc -w)
        if [ $required_interfaces_up -eq $total_required_interfaces ] && [ $required_interfaces_down -eq 0 ]; then
            log_message "Required interfaces: ALL UP ($required_interfaces_up/$total_required_interfaces)"
            return 0
        else
            log_message "Required interfaces: $required_interfaces_down DOWN, $required_interfaces_up UP (need all $total_required_interfaces)"
            return 1
        fi
    else
        # Any interface sufficient - at least one must be up
        if [ $interfaces_up -gt 0 ]; then
            log_message "Interfaces: $interfaces_up UP, $interfaces_down DOWN (any interface sufficient)"
            return 0
        else
            log_message "Interfaces: ALL DOWN ($interfaces_down total)"
            return 1
        fi
    fi
}

check_service_status() {
    local service="$1"
    local status_output
    local active_state
    local load_state
    
    status_output=$(systemctl show "$service" --property=ActiveState,LoadState,SubState 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_message "Service $service: QUERY FAILED"
        return 1
    fi
    
    active_state=$(echo "$status_output" | grep "ActiveState=" | cut -d'=' -f2)
    load_state=$(echo "$status_output" | grep "LoadState=" | cut -d'=' -f2)
    sub_state=$(echo "$status_output" | grep "SubState=" | cut -d'=' -f2)
    
    case "$active_state" in
        "active")
            log_message "Service $service: ACTIVE ($sub_state)"
            return 0
            ;;
        "inactive")
            log_message "Service $service: INACTIVE ($sub_state) - skipping"
            return 2
            ;;
        "failed")
            log_message "Service $service: FAILED ($sub_state)"
            return 1
            ;;
        "activating")
            log_message "Service $service: STARTING ($sub_state)"
            return 1
            ;;
        "deactivating")
            log_message "Service $service: STOPPING ($sub_state)"
            return 1
            ;;
        *)
            log_message "Service $service: UNKNOWN STATE ($active_state/$sub_state)"
            return 1
            ;;
    esac
}

check_network_services() {
    local all_services_ready=true
    local any_service_found=false
    local active_services_count=0
    local failed_services_count=0
    
    if [ -z "$ENABLED_SERVICES" ]; then
        log_message "Network services: NONE FOUND"
        return 1
    fi
    
    any_service_found=true
    
    # Optimized: Batch systemctl call for all services at once
    local batch_output
    batch_output=$(systemctl show $ENABLED_SERVICES --property=ActiveState,LoadState,SubState 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log_message "Network services: BATCH QUERY FAILED - falling back to individual checks"
        # Fallback to individual checks
        for service in $ENABLED_SERVICES; do
            check_service_status "$service"
            local status=$?
            case $status in
                0) ((active_services_count++)) ;;
                1) all_services_ready=false; ((failed_services_count++)) ;;
            esac
        done
    else
        # Process batched results
        local current_service=""
        local service_index=0
        local services_array=($ENABLED_SERVICES)
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^ActiveState= ]]; then
                current_service="${services_array[$service_index]}"
                local active_state="${line#ActiveState=}"
                local load_state sub_state
                
                # Read next two lines for LoadState and SubState
                read -r load_line
                read -r sub_line
                load_state="${load_line#LoadState=}"
                sub_state="${sub_line#SubState=}"
                
                # Process service status
                case "$active_state" in
                    "active")
                        log_message "Service $current_service: ACTIVE ($sub_state)"
                        ((active_services_count++))
                        ;;
                    "inactive")
                        log_message "Service $current_service: INACTIVE ($sub_state) - skipping"
                        ;;
                    "failed")
                        log_message "Service $current_service: FAILED ($sub_state)"
                        all_services_ready=false
                        ((failed_services_count++))
                        ;;
                    "activating")
                        log_message "Service $current_service: STARTING ($sub_state)"
                        all_services_ready=false
                        ((failed_services_count++))
                        ;;
                    *)
                        log_message "Service $current_service: UNKNOWN STATE ($active_state/$sub_state)"
                        all_services_ready=false
                        ((failed_services_count++))
                        ;;
                esac
                
                ((service_index++))
            fi
        done <<< "$batch_output"
    fi
    
    if [ "$any_service_found" = false ]; then
        log_message "Network services: NONE FOUND"
        return 1
    fi
    
    if [ "$all_services_ready" = true ]; then
        if [ $active_services_count -eq 0 ]; then
            log_message "Network services: ALL INACTIVE - waiting for services to start"
            return 1
        else
            log_message "Network services: ALL READY ($active_services_count active)"
            return 0
        fi
    else
        log_message "Network services: $failed_services_count NOT READY, $active_services_count ready"
        return 1
    fi
}

main_loop() {
    local interfaces_ready=false
    local gateway_reachable=false
    local services_ready=false
    local dns_working=false
    local nm_connectivity_full=false
    local arp_table_valid=false
    local routing_table_valid=false
    local network_complete_time=0
    
    while true; do
        current_time=$(date +%s)
        elapsed_time=$((current_time - START_TIME))
        
        current_all_up=false
        current_gateway_reachable=false
        current_services_ready=false
        current_dns_working=false
        current_nm_connectivity_full=false
        current_arp_table_valid=false
        current_routing_table_valid=false
        
        log_message "=== Network Status Check ==="
        
        if check_network_services; then
            current_services_ready=true
        fi
        
        if check_interfaces_ready; then
            current_all_up=true
        else
            current_all_up=false
        fi
        
        gateway=$(get_default_gateway)
        if check_gateway_reachability "$gateway"; then
            current_gateway_reachable=true
        fi
        
        if check_hostname_resolution "$RESOLVER_HOSTNAME"; then
            current_dns_working=true
        fi
        
        check_networkmanager_connectivity
        nm_status=$?
        if [ $nm_status -eq 0 ]; then
            current_nm_connectivity_full=true
        elif [ $nm_status -eq 2 ]; then
            # Service not available, don't consider it as working - wait for it
            current_nm_connectivity_full=false
        fi
        
        if check_arp_table; then
            current_arp_table_valid=true
        fi
        
        if check_routing_table; then
            current_routing_table_valid=true
        fi
        
        if [ "$current_all_up" = true ] && [ "$interfaces_ready" = false ]; then
            log_message "*** INTERFACES ARE NOW READY ***"
            interfaces_ready=true
        elif [ "$current_all_up" = false ] && [ "$interfaces_ready" = true ]; then
            log_message "*** INTERFACES NO LONGER READY ***"
            interfaces_ready=false
        fi
        
        if [ "$current_gateway_reachable" = true ] && [ "$gateway_reachable" = false ]; then
            log_message "*** GATEWAY IS NOW REACHABLE ***"
            gateway_reachable=true
        elif [ "$current_gateway_reachable" = false ] && [ "$gateway_reachable" = true ]; then
            log_message "*** GATEWAY IS NO LONGER REACHABLE ***"
            gateway_reachable=false
        fi
        
        if [ "$current_services_ready" = true ] && [ "$services_ready" = false ]; then
            log_message "*** NETWORK SERVICES ARE NOW READY ***"
            services_ready=true
        elif [ "$current_services_ready" = false ] && [ "$services_ready" = true ]; then
            log_message "*** NETWORK SERVICES NO LONGER READY ***"
            services_ready=false
        fi
        
        if [ "$current_dns_working" = true ] && [ "$dns_working" = false ]; then
            log_message "*** DNS RESOLUTION IS NOW WORKING ***"
            dns_working=true
        elif [ "$current_dns_working" = false ] && [ "$dns_working" = true ]; then
            log_message "*** DNS RESOLUTION NO LONGER WORKING ***"
            dns_working=false
        fi
        
        if [ "$current_nm_connectivity_full" = true ] && [ "$nm_connectivity_full" = false ]; then
            log_message "*** NETWORKMANAGER CONNECTIVITY IS NOW FULL ***"
            nm_connectivity_full=true
        elif [ "$current_nm_connectivity_full" = false ] && [ "$nm_connectivity_full" = true ]; then
            log_message "*** NETWORKMANAGER CONNECTIVITY NO LONGER FULL ***"
            nm_connectivity_full=false
        fi
        
        if [ "$current_arp_table_valid" = true ] && [ "$arp_table_valid" = false ]; then
            log_message "*** ARP TABLE IS NOW VALID ***"
            arp_table_valid=true
        elif [ "$current_arp_table_valid" = false ] && [ "$arp_table_valid" = true ]; then
            log_message "*** ARP TABLE NO LONGER VALID ***"
            arp_table_valid=false
        fi
        
        if [ "$current_routing_table_valid" = true ] && [ "$routing_table_valid" = false ]; then
            log_message "*** ROUTING TABLE IS NOW VALID ***"
            routing_table_valid=true
        elif [ "$current_routing_table_valid" = false ] && [ "$routing_table_valid" = true ]; then
            log_message "*** ROUTING TABLE NO LONGER VALID ***"
            routing_table_valid=false
        fi
        
        if [ "$interfaces_ready" = true ] && [ "$gateway_reachable" = true ] && [ "$services_ready" = true ] && [ "$dns_working" = true ] && [ "$nm_connectivity_full" = true ] && [ "$arp_table_valid" = true ] && [ "$routing_table_valid" = true ]; then
            if [ $network_complete_time -eq 0 ]; then
                network_complete_time=$current_time
                if [ "$BLOCKING_MODE" = true ]; then
                    log_message "*** NETWORK IS READY - UNBLOCKING BOOT PROCESS ***"
                else
                    log_message "*** NETWORK SETUP COMPLETE (services + interfaces + gateway + DNS + NetworkManager connectivity + ARP table + routing table) *** (will exit in ${RUN_AFTER_SUCCESS}s)"
                fi
            fi
        else
            if [ $network_complete_time -ne 0 ]; then
                if [ "$BLOCKING_MODE" = true ]; then
                    log_message "*** NETWORK NO LONGER COMPLETE - CONTINUING TO BLOCK ***"
                else
                    log_message "*** NETWORK NO LONGER COMPLETE - RESETTING SUCCESS TIMER ***"
                fi
                network_complete_time=0
            fi
        fi
        
        # Summary status message
        local status_summary="Status:"
        status_summary="$status_summary Interfaces=$([ "$current_all_up" = true ] && echo "UP" || echo "DOWN")"
        status_summary="$status_summary Gateway=$([ "$current_gateway_reachable" = true ] && echo "UP" || echo "DOWN")"
        status_summary="$status_summary Services=$([ "$current_services_ready" = true ] && echo "READY" || echo "NOT_READY")"
        status_summary="$status_summary DNS=$([ "$current_dns_working" = true ] && echo "OK" || echo "FAIL")"
        status_summary="$status_summary NetworkManager=$([ "$current_nm_connectivity_full" = true ] && echo "FULL" || echo "LIMITED")"
        status_summary="$status_summary ARP=$([ "$current_arp_table_valid" = true ] && echo "VALID" || echo "INVALID")"
        status_summary="$status_summary Routing=$([ "$current_routing_table_valid" = true ] && echo "VALID" || echo "INVALID")"
        log_message "$status_summary"
        
        # Check exit conditions after showing summary
        if [ $elapsed_time -ge $TOTAL_TIMEOUT ]; then
            log_message "*** TOTAL TIMEOUT REACHED (${TOTAL_TIMEOUT}s) - EXITING ***"
            cleanup
        fi
        
        if [ "$interfaces_ready" = true ] && [ "$gateway_reachable" = true ] && [ "$services_ready" = true ] && [ "$dns_working" = true ] && [ "$nm_connectivity_full" = true ] && [ "$arp_table_valid" = true ] && [ "$routing_table_valid" = true ]; then
            if [ "$BLOCKING_MODE" = true ]; then
                # In blocking mode, exit immediately when network is ready
                cleanup
            elif [ $network_complete_time -ne 0 ]; then
                # In monitoring mode, check if RUN_AFTER_SUCCESS period is complete
                time_since_complete=$((current_time - network_complete_time))
                if [ $time_since_complete -ge $RUN_AFTER_SUCCESS ]; then
                    log_message "*** RUN-AFTER-SUCCESS PERIOD COMPLETE (${RUN_AFTER_SUCCESS}s) - EXITING ***"
                    cleanup
                fi
            fi
        fi
        
        sleep "$SLEEP_INTERVAL"
    done
}

main_loop

#!/bin/bash

LOGFILE="/var/log/network_startup_monitor.log"
LOCKFILE="/var/run/network_monitor.lock"
SLEEP_INTERVAL=1
TOTAL_TIMEOUT=900
RUN_AFTER_SUCCESS=60
PING_TIMEOUT=1
BLOCKING_MODE=false
INTERFACE_TYPES="ethernet bond"
NETWORK_SERVICES="systemd-networkd.service systemd-networkd-wait-online.service NetworkManager.service NetworkManager-wait-online.service systemd-resolved.service networking.service dhcpcd.service wpa_supplicant.service"
RESOLVER_HOSTNAME="google.com"
DNS_TIMEOUT=3

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --blocking)
            BLOCKING_MODE=true
            RUN_AFTER_SUCCESS=0
            shift
            ;;
        *)
            echo "Unknown option: $1"
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

log_message() {
    # Check for log rotation before writing
    rotate_log_file
    echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') - $1" | tee -a "$LOGFILE"
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
        carrier=$(cat "$carrier_file" 2>/dev/null || echo "unknown")
        operstate=$(cat "$operstate_file" 2>/dev/null || echo "unknown")
        
        case "$carrier" in
            "1") carrier_status="UP" ;;
            "0") carrier_status="DOWN" ;;
            *) carrier_status="UNKNOWN" ;;
        esac
        
        log_message "Interface $interface: carrier=$carrier_status, operstate=$operstate"
        return 0
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
    
    if nslookup "$hostname" >/dev/null 2>&1; then
        log_message "DNS resolution for $hostname: SUCCESS"
        return 0
    elif host "$hostname" >/dev/null 2>&1; then
        log_message "DNS resolution for $hostname: SUCCESS (via host)"
        return 0
    elif getent hosts "$hostname" >/dev/null 2>&1; then
        log_message "DNS resolution for $hostname: SUCCESS (via getent)"
        return 0
    else
        log_message "DNS resolution for $hostname: FAILED (${DNS_TIMEOUT}s timeout)"
        return 1
    fi
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
            "bond")
                if is_bond_interface "$interface"; then
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

get_active_interfaces() {
    local all_interfaces=$(ip link show | grep -E '^[0-9]+:' | grep -v 'lo:' | awk -F': ' '{print $2}' | awk '{print $1}')
    local filtered_interfaces=""
    
    for interface in $all_interfaces; do
        if is_interface_type_monitored "$interface"; then
            filtered_interfaces="$filtered_interfaces $interface"
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
    
    # Check each enabled service individually to get detailed status
    for service in $ENABLED_SERVICES; do
        check_service_status "$service"
        local status=$?
        case $status in
            0)  # Active - count as ready
                ((active_services_count++))
                ;;
            1)  # Failed/Starting/Stopping - count as not ready
                all_services_ready=false
                ((failed_services_count++))
                ;;
            2)  # Inactive - skip, don't count against readiness
                ;;
        esac
    done
    
    if [ "$any_service_found" = false ]; then
        log_message "Network services: NONE FOUND"
        return 1
    fi
    
    if [ "$all_services_ready" = true ]; then
        if [ $active_services_count -eq 0 ]; then
            log_message "Network services: ALL INACTIVE - skipping service checks"
            return 0
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
    local all_interfaces_up=false
    local gateway_reachable=false
    local services_ready=false
    local dns_working=false
    local network_complete_time=0
    
    while true; do
        current_time=$(date +%s)
        elapsed_time=$((current_time - START_TIME))
        
        if [ $elapsed_time -ge $TOTAL_TIMEOUT ]; then
            log_message "*** TOTAL TIMEOUT REACHED (${TOTAL_TIMEOUT}s) - EXITING ***"
            cleanup
        fi
        current_all_up=true
        current_gateway_reachable=false
        current_services_ready=false
        current_dns_working=false
        
        log_message "=== Network Status Check ==="
        
        if check_network_services; then
            current_services_ready=true
        fi
        
        interfaces=$(get_active_interfaces)
        if [ -z "$interfaces" ]; then
            log_message "No network interfaces found"
            current_all_up=false
        else
            for interface in $interfaces; do
                if ! check_interface_status "$interface"; then
                    current_all_up=false
                fi
                
                carrier_file="/sys/class/net/$interface/carrier"
                if [ -f "$carrier_file" ]; then
                    carrier=$(cat "$carrier_file" 2>/dev/null || echo "0")
                    if [ "$carrier" != "1" ]; then
                        current_all_up=false
                    fi
                fi
                
                if is_bond_interface "$interface"; then
                    if ! check_bond_status "$interface"; then
                        current_all_up=false
                    fi
                fi
            done
        fi
        
        gateway=$(get_default_gateway)
        if check_gateway_reachability "$gateway"; then
            current_gateway_reachable=true
        fi
        
        if check_hostname_resolution "$RESOLVER_HOSTNAME"; then
            current_dns_working=true
        fi
        
        if [ "$current_all_up" = true ] && [ "$all_interfaces_up" = false ]; then
            log_message "*** ALL INTERFACES ARE NOW UP ***"
            all_interfaces_up=true
        elif [ "$current_all_up" = false ] && [ "$all_interfaces_up" = true ]; then
            log_message "*** SOME INTERFACES ARE DOWN ***"
            all_interfaces_up=false
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
        
        if [ "$all_interfaces_up" = true ] && [ "$gateway_reachable" = true ] && [ "$services_ready" = true ] && [ "$dns_working" = true ]; then
            if [ $network_complete_time -eq 0 ]; then
                network_complete_time=$current_time
                if [ "$BLOCKING_MODE" = true ]; then
                    log_message "*** NETWORK IS READY - UNBLOCKING BOOT PROCESS ***"
                    cleanup
                else
                    log_message "*** NETWORK SETUP COMPLETE (services + interfaces + gateway + DNS) *** (will exit in ${RUN_AFTER_SUCCESS}s)"
                fi
            else
                time_since_complete=$((current_time - network_complete_time))
                if [ $time_since_complete -ge $RUN_AFTER_SUCCESS ]; then
                    log_message "*** RUN-AFTER-SUCCESS PERIOD COMPLETE (${RUN_AFTER_SUCCESS}s) - EXITING ***"
                    cleanup
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
        
        sleep "$SLEEP_INTERVAL"
    done
}

main_loop
#!/bin/bash

LOGFILE="/var/log/network_monitor.log"
LOCKFILE="/var/run/network_monitor.lock"
SLEEP_INTERVAL=5
TOTAL_TIMEOUT=900
RUN_AFTER_SUCCESS=60
PING_TIMEOUT=1
BLOCKING_MODE=false
NETWORK_SERVICES="systemd-networkd.service NetworkManager.service systemd-resolved.service networking.service dhcpcd.service wpa_supplicant.service"

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

log_message() {
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

get_active_interfaces() {
    ip link show | grep -E '^[0-9]+:' | grep -v 'lo:' | awk -F': ' '{print $2}' | awk '{print $1}'
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
    
    if ! systemctl list-unit-files | grep -q "^$service"; then
        return 1
    fi
    
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
            log_message "Service $service: INACTIVE ($sub_state)"
            return 1
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
    
    for service in $NETWORK_SERVICES; do
        if systemctl list-unit-files | grep -q "^$service"; then
            any_service_found=true
            if ! check_service_status "$service"; then
                all_services_ready=false
            fi
        fi
    done
    
    if [ "$any_service_found" = false ]; then
        log_message "Network services: NONE FOUND"
        return 1
    fi
    
    if [ "$all_services_ready" = true ]; then
        log_message "Network services: ALL READY"
        return 0
    else
        log_message "Network services: SOME NOT READY"
        return 1
    fi
}

main_loop() {
    local all_interfaces_up=false
    local gateway_reachable=false
    local services_ready=false
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
        
        if [ "$all_interfaces_up" = true ] && [ "$gateway_reachable" = true ] && [ "$services_ready" = true ]; then
            if [ $network_complete_time -eq 0 ]; then
                network_complete_time=$current_time
                if [ "$BLOCKING_MODE" = true ]; then
                    log_message "*** NETWORK IS READY - UNBLOCKING BOOT PROCESS ***"
                    cleanup
                else
                    log_message "*** NETWORK SETUP COMPLETE (services + interfaces + gateway) *** (will exit in ${RUN_AFTER_SUCCESS}s)"
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
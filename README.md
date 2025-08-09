# Network Setup Monitor

A comprehensive network monitoring service that tracks network interface status, bond/LACP health, systemd service states, and gateway reachability during server startup and operation.

## Features

- **Interface Monitoring**: Monitors all active network interfaces for carrier and connection status
- **Bond/LACP Support**: Full bond interface monitoring including LACP negotiation state verification
- **Service Monitoring**: Tracks network-related systemd services (NetworkManager, systemd-networkd, etc.)
- **Gateway Testing**: Checks default gateway reachability via ping
- **DNS Resolution**: Verifies hostname resolution capability
- **NetworkManager Connectivity**: Checks NetworkManager connectivity state when available
- **ARP Table Validation**: Monitors ARP entries per interface and gateway MAC resolution
- **Routing Table Convergence**: Validates routing table population and default route presence
- **Smart Exit Conditions**: Exits after 15 minutes total OR 1 minute after network is fully operational
- **Detailed Logging**: Millisecond timestamps and comprehensive status tracking
- **Flexible Deployment**: Can run as systemd service or ad hoc

## Files

- `network_monitor.sh` - Main monitoring script
- `network-monitor.service` - Non-blocking systemd service file
- `network-wait.service` - Blocking systemd service file (blocks network-online.target)
- `install.sh` - Installation script for non-blocking mode
- `install-wait.sh` - Installation script for blocking mode
- `README.md` - This documentation

## Installation

### Non-Blocking Mode (Recommended)

For monitoring without affecting boot time:

```bash
sudo ./install.sh
```

### Blocking Mode (Boot Dependency)

To block the boot process until network is fully ready:

```bash
sudo ./install-wait.sh
```

**⚠️ Warning**: Blocking mode will delay boot completion until network is verified. Use only when services require guaranteed network connectivity.

Both installations:
- Copy the appropriate service file to `/etc/systemd/system/`
- Enable the service for automatic startup
- Create log file with proper permissions

## Usage

### As a Systemd Service

#### Non-Blocking Service (network-monitor)
Start the service:
```bash
sudo systemctl start network-monitor
```

Check status:
```bash
sudo systemctl status network-monitor
```

View logs:
```bash
# Systemd journal
sudo journalctl -u network-monitor -f

# Log file
sudo tail -f /var/log/network_startup_monitor.log
```

#### Blocking Service (network-wait)
The blocking service starts automatically during boot and blocks `network-online.target`.

Check status:
```bash
sudo systemctl status network-wait
```

View logs:
```bash
# Systemd journal
sudo journalctl -u network-wait -f

# Log file  
sudo tail -f /var/log/network_startup_monitor.log
```

Test manually:
```bash
sudo systemctl start network-wait
```

### Ad Hoc Execution

Run directly for troubleshooting or testing:
```bash
# Standard monitoring mode
sudo ./network_monitor.sh

# Blocking mode (exits immediately when network ready)
sudo ./network_monitor.sh --blocking

# With custom timeouts
sudo TOTAL_TIMEOUT=300 RUN_AFTER_SUCCESS=30 ./network_monitor.sh
```

## Configuration

Environment variables can customize behavior:

- `TOTAL_TIMEOUT` - Maximum runtime in seconds (default: 900 = 15 minutes)
- `RUN_AFTER_SUCCESS` - Time to run after network complete (default: 60 = 1 minute)
- `SLEEP_INTERVAL` - Check interval in seconds (default: 1)
- `PING_TIMEOUT` - Gateway ping timeout in seconds (default: 1)
- `INTERFACE_TYPES` - Space-separated interface types to monitor (default: "ethernet bond")
- `NETWORK_SERVICES` - Space-separated list of services to monitor
- `RESOLVER_HOSTNAME` - Hostname for DNS resolution testing (default: "google.com")
- `DNS_TIMEOUT` - DNS resolution timeout in seconds (default: 3)

**Interface Types:**
- `ethernet` - Ethernet interfaces (default)
- `wireless` - Wireless/WiFi interfaces
- `bond` - Bond interfaces (default)
- `tunnel` - Tunnel interfaces (VPN, etc.)
- `all` - Monitor all interface types
- `other` - Other/unknown interface types

Example:
```bash
# Monitor ethernet and wireless interfaces
sudo INTERFACE_TYPES="ethernet wireless" ./network_monitor.sh

# Monitor all interfaces with custom timeouts
sudo INTERFACE_TYPES="all" TOTAL_TIMEOUT=1800 PING_TIMEOUT=3 ./network_monitor.sh
```

## Exit Conditions

The script exits when either condition is met:

1. **Total Timeout**: 15 minutes (900s) from startup
2. **Run-After-Success**: 1 minute (60s) after network becomes fully operational

Network is considered "fully operational" when ALL of these are true:
- All network interfaces have carrier signal
- All bond interfaces have completed LACP negotiation (if applicable)
- All network services are active
- Default gateway is reachable
- DNS hostname resolution is working
- NetworkManager connectivity check passes (when available)
- ARP table contains gateway MAC address resolution
- Routing table has valid default route configuration

## Monitoring Scope

### Network Interfaces
- Carrier status (physical link)
- Operational state
- Bond interface health
- LACP negotiation status for 802.3ad bonds
- Active slave verification for active-backup bonds

### Network Services
Monitors these systemd services (if present):
- `systemd-networkd.service`
- `systemd-networkd-wait-online.service`
- `NetworkManager.service`
- `NetworkManager-wait-online.service`
- `systemd-resolved.service`
- `networking.service`
- `dhcpcd.service`
- `wpa_supplicant.service`

### Gateway Connectivity
- Discovers default gateway via routing table
- Tests reachability with single ping (configurable timeout, default 1 second)

### DNS Resolution
- Tests hostname resolution using configurable hostname (default: google.com)
- Configurable timeout for DNS queries (default: 3 seconds)

### NetworkManager Integration
- Checks NetworkManager connectivity state when available
- Provides additional verification beyond basic network tests

### ARP Table Validation
- Monitors ARP entries per active network interface
- Validates gateway IP to MAC address resolution
- Detects incomplete link-layer negotiation issues
- Critical for troubleshooting bond interface startup delays

### Routing Table Convergence
- Reports total routes, default routes, network routes, and host routes
- Validates presence and details of default route
- Shows route metrics for debugging path selection
- Ensures kernel routing table is fully populated

## Log Format

All log entries include millisecond timestamps (`YYYY-MM-DD HH:MM:SS.mmm`):

### Startup Banner
```
2025-01-15 10:30:10.123 - =============================================================
2025-01-15 10:30:10.124 -     NETWORK STARTUP MONITOR SERVICE - Wed Jan 15 10:30:10 UTC 2025
2025-01-15 10:30:10.125 - =============================================================
2025-01-15 10:30:10.126 - PID: 1234
2025-01-15 10:30:10.127 - Mode: MONITORING
2025-01-15 10:30:10.128 - Timeouts: Total=900s, AfterSuccess=60s, Sleep=1s
2025-01-15 10:30:10.129 - Interface Types: ethernet bond
2025-01-15 10:30:10.130 - DNS Resolver: google.com (timeout: 3s)
2025-01-15 10:30:10.131 - Ping Timeout: 1s
2025-01-15 10:30:10.132 - =============================================================
```

### Interface Status
```
2025-01-15 10:30:15.123 - Interface eth0: carrier=UP, operstate=up
2025-01-15 10:30:15.456 - Interface eth1: carrier=DOWN, operstate=down
```

### Bond Status
```
2025-01-15 10:30:16.123 - Bond bond0: mode=IEEE 802.3ad Dynamic link aggregation, mii_status=up, active_slave=eth1, slaves=2/2
2025-01-15 10:30:16.456 - Bond bond0 slave eth0: LACP negotiated (state: 3f)
2025-01-15 10:30:16.789 - Bond bond0: LACP negotiation complete
2025-01-15 10:30:17.012 - Bond bond0: HEALTHY
```

### Service Status
```
2025-01-15 10:30:15.234 - Service systemd-networkd.service: STARTING (start-pre)
2025-01-15 10:30:16.567 - Service systemd-networkd.service: ACTIVE (running)
2025-01-15 10:30:17.890 - *** NETWORK SERVICES ARE NOW READY ***
```

### Gateway Status
```
2025-01-15 10:30:18.123 - Gateway 192.168.1.1: REACHABLE (1s timeout)
2025-01-15 10:30:18.456 - *** GATEWAY IS NOW REACHABLE ***
```

### DNS Resolution Status
```
2025-01-15 10:30:19.123 - DNS resolution for google.com: SUCCESS (3s timeout)
2025-01-15 10:30:19.456 - *** DNS RESOLUTION IS NOW WORKING ***
```

### NetworkManager Connectivity
```
2025-01-15 10:30:20.123 - NetworkManager connectivity: FULL
```

### ARP Table Status
```
2025-01-15 10:30:21.123 - --- ARP Table Status ---
2025-01-15 10:30:21.234 - ARP table eth0: 0 entries
2025-01-15 10:30:21.345 - ARP table bond0: 3 entries (gateway 192.168.1.1 -> aa:bb:cc:dd:ee:ff)
2025-01-15 10:30:21.456 - ARP table total: 3 entries
2025-01-15 10:30:21.567 - ARP table gateway: 192.168.1.1 RESOLVED
2025-01-15 10:30:21.678 - *** ARP TABLE IS NOW VALID ***
```

### Routing Table Status
```
2025-01-15 10:30:22.123 - --- Routing Table Status ---
2025-01-15 10:30:22.234 - Routing table: 8 total routes
2025-01-15 10:30:22.345 - Routing table: 1 default routes
2025-01-15 10:30:22.456 - Routing table: 3 network routes
2025-01-15 10:30:22.567 - Routing table: 2 host routes
2025-01-15 10:30:22.678 - Default route: 192.168.1.1 via bond0 (metric 100)
2025-01-15 10:30:22.789 - *** ROUTING TABLE HAS DEFAULT ROUTE ***
2025-01-15 10:30:22.890 - *** ROUTING TABLE IS NOW VALID ***
```

### Completion Status
```
2025-01-15 10:30:23.123 - *** NETWORK SETUP COMPLETE (services + interfaces + gateway + DNS + NetworkManager connectivity + ARP table + routing table) *** (will exit in 60s)
2025-01-15 10:31:20.456 - *** RUN-AFTER-SUCCESS PERIOD COMPLETE (60s) - EXITING ***
```

## Systemd Integration

### Non-Blocking Service (network-monitor.service)
- Runs **before** network services start
- Does **not block** boot process or other services
- Exits automatically after network ready + timeout
- Automatically restarts on failure

### Blocking Service (network-wait.service)
- Runs **after** basic network services (`After=systemd-networkd.service NetworkManager.service...`)
- **Blocks** `network-online.target` until network is verified
- Uses `Type=oneshot` with `RemainAfterExit=yes`
- Services depending on `network-online.target` wait for this check
- Maximum timeout: 15 minutes (`TimeoutStartSec=900`)

## Troubleshooting

### Service Won't Start
Check for existing lockfile:
```bash
sudo rm -f /var/run/network_monitor.lock
```

### No Network Services Found
The script automatically detects which network services are installed. If none are found, it logs "Network services: NONE FOUND" but continues monitoring interfaces and gateway.

### Permission Issues
Ensure the script runs as root - it needs access to:
- `/proc/net/bonding/` for bond status
- `/sys/class/net/` for interface status  
- `systemctl` commands for service monitoring
- Network commands (`ip`, `ping`)

### Log File Access
Log file location: `/var/log/network_startup_monitor.log`
Ensure proper permissions are set during installation.

## Performance Considerations

**Interface Discovery**: The script intentionally does NOT cache network interface discovery results. This is critical for boot-time troubleshooting because:
- Interfaces are frequently created/renamed/removed during system startup
- Bond interfaces may not exist initially and get created during LACP negotiation
- Network managers (NetworkManager, systemd-networkd) can rename interfaces
- Udev rules may cause interface name changes
- Hot-plugged network devices appear during boot

Caching interface discovery would prevent detection of these dynamic changes, which are often the root cause of network startup delays.

## Performance Optimizations

The script includes several performance optimizations to minimize system overhead during boot:

**Optimized Log Rotation**: Log file rotation is checked every 10 messages instead of every message, reducing file system overhead while maintaining log management.

**Batched Service Checks**: Network services are queried using a single batched `systemctl show` command instead of individual calls, significantly reducing systemd interaction overhead. Falls back to individual checks if batch operation fails.

**Single-Pass Processing**: Route table analysis and ARP table processing use single-pass algorithms instead of multiple grep/wc command pipelines, eliminating redundant data processing.

**Combined File Operations**: Interface status checks combine carrier and operstate file reads using compound redirection, reducing file system I/O operations.

These optimizations maintain full diagnostic accuracy while minimizing resource usage during the critical boot phase when system performance matters most.

## Use Cases

### Non-Blocking Mode
- **Server Startup Monitoring**: Track network initialization progress during boot
- **Bond/LACP Verification**: Ensure LACP negotiation completes properly
- **Service Dependency Tracking**: Monitor network service startup sequence
- **Troubleshooting**: Ad hoc network status checking
- **Automation**: Integration with deployment and monitoring systems

### Blocking Mode
- **Critical Services**: Ensure network is ready before starting database clusters, web services, etc.
- **Container Orchestration**: Block node readiness until network is verified
- **Network-Dependent Applications**: Guarantee connectivity before application startup
- **High-Availability Systems**: Prevent split-brain scenarios by ensuring network readiness
- **Automated Deployments**: Block deployment completion until network verification

## Service Comparison

| Feature | Non-Blocking (`network-monitor`) | Blocking (`network-wait`) |
|---------|--------------------------------|--------------------------|
| Boot Impact | No delay | Delays boot until network ready |
| Exit Behavior | Runs for timeout period | Exits immediately when ready |
| Use Case | Monitoring & logging | Boot dependency |
| Target Dependency | None | Blocks `network-online.target` |
| Service Type | `simple` with restart | `oneshot` with `RemainAfterExit` |
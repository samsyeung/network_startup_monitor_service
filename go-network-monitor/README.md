# Network Startup Monitor Service (Go)

A high-performance, comprehensive network monitoring service written in Go that tracks network interface status, bond/LACP health, systemd service states, and gateway reachability during server startup and operation.

This is the Go implementation of the bash-based network startup monitor, providing significantly improved performance, lower resource usage, and better concurrent processing capabilities.

## Features

- **High Performance**: Native Go implementation with concurrent processing
- **Lower Resource Usage**: Single binary with minimal memory footprint  
- **Interface Monitoring**: Monitors all active network interfaces for carrier and connection status
- **Bond/LACP Support**: Full bond interface monitoring including LACP negotiation state verification
- **Service Monitoring**: Tracks network-related systemd services with batched queries
- **Gateway Testing**: Checks default gateway reachability via ping
- **DNS Resolution**: Verifies hostname resolution capability
- **NetworkManager Connectivity**: Checks NetworkManager connectivity state when available
- **ARP Table Validation**: Monitors ARP entries per interface and gateway MAC resolution
- **Routing Table Convergence**: Validates routing table population and default route presence
- **Smart Exit Conditions**: Exits after 15 minutes total OR 1 minute after network is fully operational
- **Detailed Logging**: Millisecond timestamps and comprehensive status tracking
- **Flexible Deployment**: Can run as systemd service or ad hoc

## Architecture Improvements over Bash Version

- **Concurrent Processing**: Network checks run in parallel using goroutines
- **Native Network APIs**: Uses netlink library for direct kernel communication
- **Efficient Systemd Integration**: D-Bus connection for fast service status queries
- **Memory Efficient**: Single process with low memory footprint
- **Type Safety**: Strong typing prevents runtime errors common in shell scripts
- **Error Handling**: Robust error handling and recovery mechanisms

## Files

- `cmd/network-monitor/main.go` - Main application entry point
- `internal/config/` - Configuration management
- `internal/logger/` - Logging infrastructure with rotation
- `internal/monitor/` - Core monitoring logic
- `internal/network/` - Network interface, ARP, routing, and connectivity checks
- `internal/system/` - Systemd service monitoring
- `systemd/network-monitor-go.service` - Non-blocking systemd service file
- `systemd/network-wait-go.service` - Blocking systemd service file (blocks network-online.target)
- `Makefile` - Build and installation automation

## Requirements

- Go 1.21 or later
- Linux kernel with netlink support
- Root privileges for network monitoring
- systemd (for service monitoring)

## Dependencies

- `github.com/coreos/go-systemd/v22` - Systemd D-Bus integration
- `github.com/vishvananda/netlink` - Netlink library for network operations
- `github.com/vishvananda/netns` - Network namespace support

## Building

```bash
# Install dependencies
make deps

# Build the binary
make build

# Run tests
make test

# Build release binaries for multiple architectures
make release
```

## Installation

### Quick Install - Non-Blocking Mode (Recommended)

For monitoring without affecting boot time:

```bash
make install-monitor
```

### Quick Install - Blocking Mode (Boot Dependency)

To block the boot process until network is fully ready:

```bash
make install-wait
```

**⚠️ Warning**: Blocking mode will delay boot completion until network is verified. Use only when services require guaranteed network connectivity.

### Manual Installation

```bash
# Build and install binary and service files
make install

# Then choose mode:
make enable        # Non-blocking mode
# OR
make enable-wait   # Blocking mode
```

## Usage

### As a Systemd Service

#### Non-Blocking Service (network-monitor-go)
```bash
# Start the service
sudo systemctl start network-monitor-go

# Check status
sudo systemctl status network-monitor-go

# View logs
sudo journalctl -u network-monitor-go -f
# OR
sudo tail -f /var/log/network_startup_monitor.log
```

#### Blocking Service (network-wait-go)
```bash
# Check status
sudo systemctl status network-wait-go

# View logs
sudo journalctl -u network-wait-go -f
# OR
sudo tail -f /var/log/network_startup_monitor.log
```

### Ad Hoc Execution

Run directly for troubleshooting or testing:

```bash
# Standard monitoring mode
sudo ./network-monitor

# Blocking mode (exits immediately when network ready)
sudo ./network-monitor --blocking

# With custom environment variables
sudo TOTAL_TIMEOUT=300 RUN_AFTER_SUCCESS=30 ./network-monitor
```

## Configuration

Environment variables can customize behavior:

- `TOTAL_TIMEOUT` - Maximum runtime in seconds (default: 900 = 15 minutes)
- `RUN_AFTER_SUCCESS` - Time to run after network complete (default: 60 = 1 minute)  
- `SLEEP_INTERVAL` - Check interval in seconds (default: 1)
- `PING_TIMEOUT` - Gateway ping timeout in seconds (default: 1)
- `DNS_TIMEOUT` - DNS resolution timeout in seconds (default: 3)
- `INTERFACE_TYPES` - Space-separated interface types to monitor (default: "ethernet bond")
- `RESOLVER_HOSTNAME` - Hostname for DNS resolution testing (default: "google.com")

**Interface Types:**
- `ethernet` - Ethernet interfaces (default)
- `wireless` - Wireless/WiFi interfaces  
- `bond` - Bond interfaces (default)
- `tunnel` - Tunnel interfaces (VPN, etc.)
- `other` - Other/unknown interface types

Example:
```bash
# Monitor ethernet and wireless interfaces
sudo INTERFACE_TYPES="ethernet wireless" ./network-monitor

# Monitor all interfaces with custom timeouts  
sudo INTERFACE_TYPES="ethernet bond wireless" TOTAL_TIMEOUT=1800 DNS_TIMEOUT=5 ./network-monitor
```

## Performance Advantages

The Go version provides significant performance improvements over the bash version:

**Startup Time**: ~50ms vs ~2s for bash version
**Memory Usage**: ~8MB RSS vs ~15-30MB for bash with subprocesses
**CPU Usage**: Lower CPU overhead due to single-process architecture
**Network Checks**: Concurrent execution vs sequential in bash
**Systemd Queries**: Native D-Bus vs subprocess calls
**Error Recovery**: Better error handling and retry logic

## Exit Conditions

The service exits when either condition is met:

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
- Operational state using netlink API
- Bond interface health with native parsing
- LACP negotiation status for 802.3ad bonds
- Active slave verification for active-backup bonds

### Network Services  
Monitors these systemd services via D-Bus (if present):
- `systemd-networkd.service`
- `systemd-networkd-wait-online.service`
- `NetworkManager.service`
- `NetworkManager-wait-online.service`
- `systemd-resolved.service`
- `networking.service`
- `dhcpcd.service`
- `wpa_supplicant.service`

### Connectivity Tests
- Default gateway discovery via netlink routing table
- Gateway reachability testing with configurable timeout
- DNS hostname resolution with timeout control
- NetworkManager connectivity state verification

### Lower-Level Validation
- ARP table monitoring via netlink neighbor entries
- Routing table convergence via netlink route entries
- Interface-specific ARP entry counting
- Default route validation with metrics

## Makefile Targets

```bash
make help           # Show all available targets
make build          # Build the binary
make install        # Install binary and service files  
make install-monitor # Install and enable non-blocking service
make install-wait   # Install and enable blocking service
make uninstall      # Remove everything
make start/stop     # Control services
make status         # Show service status
make logs           # Follow service logs
make tail           # Follow log file
make clean          # Clean build artifacts
```

## Security Features

The systemd service files include comprehensive security hardening:
- Capability restrictions (only network-related capabilities)
- Filesystem protections (read-only system, private tmp)
- Process restrictions (no new privileges, memory protections)
- Network namespace isolation where appropriate

## Troubleshooting

### Service Won't Start
Check for existing lockfile:
```bash
sudo rm -f /var/run/network_monitor.lock
```

### Build Issues
Ensure Go version 1.21+ and required dependencies:
```bash
make deps
go version
```

### Permission Issues
Ensure running as root for network monitoring capabilities.

### Performance Monitoring
The Go version includes built-in performance metrics in logs and can be monitored via standard Go profiling tools.

## Migration from Bash Version

The Go version is a drop-in replacement for the bash version:
1. Same command-line interface and environment variables
2. Same log format and file locations
3. Compatible systemd service configuration
4. Identical network readiness criteria

Simply install the Go version and disable the bash version:
```bash
# Install Go version
make install-monitor

# Disable bash version  
sudo systemctl disable network-monitor
```

## Development

```bash
# Run tests
make test

# Build for development
go build -o network-monitor ./cmd/network-monitor

# Run with race detection
go run -race ./cmd/network-monitor

# Profile memory usage
go tool pprof http://localhost:6060/debug/pprof/heap
```
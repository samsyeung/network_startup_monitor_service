# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains a comprehensive network monitoring service for Linux systems that verifies network readiness during system startup. The core architecture consists of a single bash script (`network_monitor.sh`) that can operate in two distinct modes with different systemd service configurations.

## Architecture

### Core Components

**Main Script (`network_monitor.sh`)**:
- Single bash script with dual-mode operation (monitoring vs blocking)
- Configurable via environment variables and command-line flags
- Comprehensive network state verification including interfaces, bonds/LACP, systemd services, and gateway connectivity
- Smart exit conditions based on timeouts or network readiness

**Service Configurations**:
- `network-monitor.service`: Non-blocking monitoring service that runs in parallel with boot
- `network-wait.service`: Blocking service that delays `network-online.target` until network is verified

### Monitoring Scope

The script performs comprehensive checks across four key areas:
1. **Network Interfaces**: Physical carrier status and operational state for all active interfaces
2. **Bond Interfaces**: LACP negotiation verification, active slave status, and bond health
3. **Systemd Services**: Status monitoring of network-related services (NetworkManager, systemd-networkd, etc.)
4. **Gateway Connectivity**: Default gateway discovery and reachability testing via ping

### Operating Modes

**Non-Blocking Mode** (default):
- Runs continuously for monitoring and logging
- Exits after total timeout (15 min) or run-after-success period (1 min after network ready)
- Does not affect boot timing

**Blocking Mode** (`--blocking` flag):
- Exits immediately when network is fully operational
- Used by `network-wait.service` to block boot process
- Critical for services requiring guaranteed network connectivity

## Configuration

### Environment Variables
All timeouts and behavior can be customized via environment variables:
- `TOTAL_TIMEOUT`: Maximum runtime (default: 900s)
- `RUN_AFTER_SUCCESS`: Time to run after network complete (default: 60s) 
- `SLEEP_INTERVAL`: Check frequency (default: 5s)
- `PING_TIMEOUT`: Gateway ping timeout (default: 1s)
- `NETWORK_SERVICES`: Space-separated list of services to monitor

### Service Files
The systemd service files are configured for different use cases:
- Non-blocking service runs early (`Before=network services`) without affecting boot
- Blocking service runs after basic network services and blocks `network-online.target`

## Common Operations

### Installation
```bash
# Non-blocking monitoring mode
sudo ./install.sh

# Blocking mode (delays boot until network ready)  
sudo ./install-wait.sh
```

### Testing and Debugging
```bash
# Run in monitoring mode
sudo ./network_monitor.sh

# Run in blocking mode (exits when ready)
sudo ./network_monitor.sh --blocking

# Custom configuration
sudo PING_TIMEOUT=3 TOTAL_TIMEOUT=600 ./network_monitor.sh

# Check service status
sudo systemctl status network-monitor  # or network-wait
sudo journalctl -u network-monitor -f
sudo tail -f /var/log/network_monitor.log
```

### Service Management
```bash
# Start/stop/restart services
sudo systemctl start network-monitor
sudo systemctl stop network-monitor
sudo systemctl restart network-monitor

# Enable/disable automatic startup
sudo systemctl enable network-monitor
sudo systemctl disable network-monitor
```

## Network Readiness Criteria

The script considers the network "fully operational" when ALL conditions are met:
1. All network interfaces have carrier signal (physical link up)
2. All bond interfaces have completed LACP negotiation (if applicable)
3. All detected network services are in active state
4. Default gateway is reachable via ping

## Bond/LACP Verification

The script includes sophisticated bond interface monitoring:
- Detects bond interfaces via `/proc/net/bonding/`
- Verifies LACP negotiation state by parsing actor LACP PDU state
- Checks collecting/distributing bits in LACP state for full negotiation
- Supports both 802.3ad (LACP) and active-backup bond modes
- Validates active slave configuration for active-backup mode

## Logging and Monitoring

All events are logged with millisecond precision timestamps to both:
- Console output (when run interactively)
- Log file (`/var/log/network_monitor.log`)
- Systemd journal (when run as service)

Key log events include interface state changes, service transitions, gateway connectivity, and network readiness milestones.

## Security Considerations

The script requires root privileges for:
- Reading network interface status from `/sys/class/net/`
- Accessing bond information in `/proc/net/bonding/`
- Querying systemd service states
- Network connectivity testing (ping, ip commands)
- Writing to system log locations
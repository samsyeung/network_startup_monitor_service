# Bond Interface Detection and Debugging

## Issues Fixed in Bond Interface Detection

### Problem
Bond interfaces were not behaving differently from regular ethernet interfaces due to redundant logic and insufficient logging.

### Root Cause Analysis

1. **Redundant Logic in Bash Script**: The `is_interface_type_monitored()` function had redundant bond checking that could interfere with proper detection
2. **Insufficient Logging**: Bond interface detection was happening but wasn't clearly visible in logs
3. **Missing Interface Discovery Logging**: No indication when bond interfaces are discovered during interface enumeration

### Fixes Applied

#### 1. Removed Redundant Bond Logic
**Before:**
```bash
case "$monitored_type" in
    "$interface_type")  # This catches "bond" type
        return 0
        ;;
    "bond")             # This was redundant!
        if is_bond_interface "$interface"; then
            return 0
        fi
        ;;
esac
```

**After:**
```bash
case "$monitored_type" in
    "$interface_type")  # This correctly catches "bond" type
        return 0
        ;;
esac
```

#### 2. Enhanced Bond Detection Logging
Added clear logging messages in both implementations:

**Bash Script:**
- `Interface discovery: bond0 (type=bond) - BOND INTERFACE FOUND`
- `Interface bond0: BOND INTERFACE DETECTED - checking bond status`
- `Interface bond0: BOND STATUS OK` or `Interface bond0: BOND STATUS FAILED - marking interface down`

**Go Implementation:**
- `Interface bond0: BOND INTERFACE DETECTED - checking bond status`
- `Interface bond0: BOND STATUS OK` or `Interface bond0: BOND STATUS FAILED - marking interface down`

## Expected Behavior with Bond Interfaces

### 1. Interface Discovery
When bond interfaces are present, you should see:
```
Interface discovery: bond0 (type=bond) - BOND INTERFACE FOUND
```

### 2. Interface Status Checking
For each bond interface during status checks:
```
Interface bond0: carrier=UP, operstate=up
Interface bond0: BOND INTERFACE DETECTED - checking bond status
Bond bond0: mode=IEEE 802.3ad Dynamic link aggregation, mii_status=up, active_slave=eth0, slaves=2/2
Bond bond0: LACP negotiation complete
Bond bond0: HEALTHY
Interface bond0: BOND STATUS OK
```

### 3. Bond Failure Scenarios
If bond interfaces have issues:
```
Interface bond0: BOND INTERFACE DETECTED - checking bond status
Bond bond0: LACP negotiation incomplete
Interface bond0: BOND STATUS FAILED - marking interface down
```

## Bond Interface Types Supported

### 1. 802.3ad (LACP) Bonds
- Checks LACP negotiation state
- Verifies collecting/distributing bits in LACP PDU state
- Requires all slaves to have completed LACP negotiation

### 2. Active-Backup Bonds
- Checks for presence of active slave
- Validates that active slave is operational

### 3. Other Bond Modes
- Basic health checks for MII status and slave availability

## Testing Bond Interface Detection

### Manual Test Commands
```bash
# Check if bond interfaces are detected by type
sudo ./network_monitor.sh --help  # Shows current interface types
sudo INTERFACE_TYPES="ethernet bond" ./network_monitor.sh --blocking

# Check bond interface files
ls -la /proc/net/bonding/
cat /proc/net/bonding/bond0  # If bond0 exists

# Check interface types
for iface in $(ip link show | awk -F': ' '/^[0-9]+:/ && !/lo:/ {print $2}'); do
    echo "Interface: $iface"
    echo "  Type file: $(cat /sys/class/net/$iface/type 2>/dev/null || echo 'missing')"
    echo "  Bond dir: $([ -d /proc/net/bonding/$iface ] && echo 'exists' || echo 'missing')"
done
```

### Expected Log Differences

**Without Bond Interfaces:**
```
Interface eth0: carrier=UP, operstate=up
```

**With Bond Interfaces:**
```
Interface discovery: bond0 (type=bond) - BOND INTERFACE FOUND
Interface bond0: carrier=UP, operstate=up
Interface bond0: BOND INTERFACE DETECTED - checking bond status
Bond bond0: mode=IEEE 802.3ad Dynamic link aggregation, mii_status=up, active_slave=eth0, slaves=2/2
Bond bond0: LACP negotiation complete
Bond bond0: HEALTHY
Interface bond0: BOND STATUS OK
```

## Configuration Requirements

To monitor bond interfaces, ensure:
1. **Interface Types**: Include "bond" in `INTERFACE_TYPES` (default: "ethernet bond")
2. **Permissions**: Script needs root access to read `/proc/net/bonding/*`
3. **Kernel Module**: `bonding` kernel module must be loaded

The enhancements should make bond interface detection much more visible and debuggable in production environments.
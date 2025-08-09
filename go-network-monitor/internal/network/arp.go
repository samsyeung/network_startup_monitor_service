package network

import (
	"fmt"
	"net"
	
	"github.com/vishvananda/netlink"
)

// ARPEntry represents an ARP table entry
type ARPEntry struct {
	IP        net.IP
	MAC       net.HardwareAddr
	Interface string
	State     string
}

// ARPTableStatus represents the status of ARP tables
type ARPTableStatus struct {
	TotalEntries     int
	GatewayResolved  bool
	GatewayMAC       net.HardwareAddr
	InterfaceEntries map[string]int
}

// ARPMonitor handles ARP table monitoring
type ARPMonitor struct{}

// NewARPMonitor creates a new ARP monitor
func NewARPMonitor() *ARPMonitor {
	return &ARPMonitor{}
}

// CheckARPTable validates ARP table entries for given interfaces
func (am *ARPMonitor) CheckARPTable(interfaces []string, gatewayIP net.IP) (*ARPTableStatus, error) {
	status := &ARPTableStatus{
		InterfaceEntries: make(map[string]int),
	}
	
	// Get all ARP entries
	neighbors, err := netlink.NeighList(0, netlink.FAMILY_V4)
	if err != nil {
		return nil, fmt.Errorf("failed to get ARP table: %w", err)
	}
	
	// Process ARP entries by interface
	for _, iface := range interfaces {
		link, err := netlink.LinkByName(iface)
		if err != nil {
			continue // Skip interfaces that don't exist
		}
		
		interfaceIndex := link.Attrs().Index
		entryCount := 0
		
		for _, neighbor := range neighbors {
			// Skip failed/incomplete entries
			if neighbor.State&(netlink.NUD_FAILED|netlink.NUD_INCOMPLETE) != 0 {
				continue
			}
			
			if neighbor.LinkIndex == interfaceIndex {
				entryCount++
				status.TotalEntries++
				
				// Check if this is the gateway
				if gatewayIP != nil && neighbor.IP.Equal(gatewayIP) {
					status.GatewayResolved = true
					status.GatewayMAC = neighbor.HardwareAddr
				}
			}
		}
		
		status.InterfaceEntries[iface] = entryCount
	}
	
	return status, nil
}

// GetARPEntriesForInterface returns ARP entries for a specific interface
func (am *ARPMonitor) GetARPEntriesForInterface(interfaceName string) ([]ARPEntry, error) {
	link, err := netlink.LinkByName(interfaceName)
	if err != nil {
		return nil, fmt.Errorf("interface %s not found: %w", interfaceName, err)
	}
	
	neighbors, err := netlink.NeighList(link.Attrs().Index, netlink.FAMILY_V4)
	if err != nil {
		return nil, fmt.Errorf("failed to get ARP entries for %s: %w", interfaceName, err)
	}
	
	var entries []ARPEntry
	for _, neighbor := range neighbors {
		// Skip failed/incomplete entries
		if neighbor.State&(netlink.NUD_FAILED|netlink.NUD_INCOMPLETE) != 0 {
			continue
		}
		
		state := "REACHABLE"
		if neighbor.State&netlink.NUD_STALE != 0 {
			state = "STALE"
		} else if neighbor.State&netlink.NUD_DELAY != 0 {
			state = "DELAY"
		} else if neighbor.State&netlink.NUD_PROBE != 0 {
			state = "PROBE"
		}
		
		entries = append(entries, ARPEntry{
			IP:        neighbor.IP,
			MAC:       neighbor.HardwareAddr,
			Interface: interfaceName,
			State:     state,
		})
	}
	
	return entries, nil
}
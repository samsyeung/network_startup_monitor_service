package network

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strings"
	
	"github.com/vishvananda/netlink"
)

// InterfaceType represents different types of network interfaces
type InterfaceType string

const (
	Ethernet InterfaceType = "ethernet"
	Bond     InterfaceType = "bond"
	Wireless InterfaceType = "wireless"
	Tunnel   InterfaceType = "tunnel"
	Other    InterfaceType = "other"
)

// InterfaceStatus represents the status of a network interface
type InterfaceStatus struct {
	Name        string
	Type        InterfaceType
	Carrier     bool
	OperState   string
	AdminState  string
	HasCarrier  bool
}

// BondStatus represents the status of a bond interface
type BondStatus struct {
	Name           string
	Mode           string
	MIIStatus      string
	ActiveSlave    string
	SlaveCount     int
	TotalSlaves    int
	LACPComplete   bool
}

// InterfaceMonitor handles network interface monitoring
type InterfaceMonitor struct {
	interfaceTypes []InterfaceType
}

// NewInterfaceMonitor creates a new interface monitor
func NewInterfaceMonitor(interfaceTypes []string) *InterfaceMonitor {
	var types []InterfaceType
	for _, t := range interfaceTypes {
		switch strings.ToLower(t) {
		case "ethernet":
			types = append(types, Ethernet)
		case "bond":
			types = append(types, Bond)
		case "wireless":
			types = append(types, Wireless)
		case "tunnel":
			types = append(types, Tunnel)
		case "other":
			types = append(types, Other)
		}
	}
	return &InterfaceMonitor{interfaceTypes: types}
}

// GetActiveInterfaces returns all active network interfaces (excluding loopback)
// IMPORTANT: Never cache this function's result - interface discovery
// during boot is one of the key things we need to troubleshoot.
func (im *InterfaceMonitor) GetActiveInterfaces() ([]string, error) {
	links, err := netlink.LinkList()
	if err != nil {
		return nil, fmt.Errorf("failed to list network interfaces: %w", err)
	}
	
	var interfaces []string
	for _, link := range links {
		name := link.Attrs().Name
		if name == "lo" {
			continue // Skip loopback
		}
		
		if im.isInterfaceTypeMonitored(name) {
			interfaces = append(interfaces, name)
		}
	}
	
	return interfaces, nil
}

// CheckInterfaceStatus checks the status of a network interface
func (im *InterfaceMonitor) CheckInterfaceStatus(interfaceName string) (*InterfaceStatus, error) {
	link, err := netlink.LinkByName(interfaceName)
	if err != nil {
		return nil, fmt.Errorf("interface %s not found: %w", interfaceName, err)
	}
	
	attrs := link.Attrs()
	status := &InterfaceStatus{
		Name: interfaceName,
		Type: im.getInterfaceType(interfaceName),
	}
	
	// Check carrier status
	carrierPath := fmt.Sprintf("/sys/class/net/%s/carrier", interfaceName)
	carrierData, err := os.ReadFile(carrierPath)
	if err == nil {
		carrier := strings.TrimSpace(string(carrierData))
		status.Carrier = (carrier == "1")
		status.HasCarrier = status.Carrier
	}
	
	// Check operational state
	operstatePath := fmt.Sprintf("/sys/class/net/%s/operstate", interfaceName)
	operstateData, err := os.ReadFile(operstatePath)
	if err == nil {
		status.OperState = strings.TrimSpace(string(operstateData))
	} else {
		status.OperState = "unknown"
	}
	
	// Determine admin state from flags
	if attrs.Flags&net.FlagUp != 0 {
		status.AdminState = "up"
	} else {
		status.AdminState = "down"
	}
	
	return status, nil
}

// CheckBondStatus checks the status of a bond interface
func (im *InterfaceMonitor) CheckBondStatus(interfaceName string) (*BondStatus, error) {
	bondPath := fmt.Sprintf("/proc/net/bonding/%s", interfaceName)
	
	file, err := os.Open(bondPath)
	if err != nil {
		return nil, fmt.Errorf("bond interface %s not found: %w", interfaceName, err)
	}
	defer file.Close()
	
	status := &BondStatus{
		Name: interfaceName,
	}
	
	scanner := bufio.NewScanner(file)
	var currentSlave string
	slaveStates := make(map[string]bool)
	
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		
		if strings.HasPrefix(line, "Bonding Mode: ") {
			status.Mode = strings.TrimPrefix(line, "Bonding Mode: ")
		} else if strings.HasPrefix(line, "MII Status: ") {
			status.MIIStatus = strings.TrimPrefix(line, "MII Status: ")
		} else if strings.HasPrefix(line, "Currently Active Slave: ") {
			status.ActiveSlave = strings.TrimPrefix(line, "Currently Active Slave: ")
		} else if strings.HasPrefix(line, "Slave Interface: ") {
			currentSlave = strings.TrimPrefix(line, "Slave Interface: ")
			status.TotalSlaves++
		} else if strings.HasPrefix(line, "MII Status: ") && currentSlave != "" {
			miiStatus := strings.TrimPrefix(line, "MII Status: ")
			if miiStatus == "up" {
				status.SlaveCount++
				slaveStates[currentSlave] = true
			}
		} else if strings.Contains(line, "Actor LACP PDU: ") && currentSlave != "" {
			// Parse LACP state for 802.3ad bonds
			if strings.Contains(line, "Collecting distributing") {
				slaveStates[currentSlave] = true
			}
		}
	}
	
	// Check if LACP is complete for 802.3ad bonds
	if strings.Contains(status.Mode, "IEEE 802.3ad") {
		status.LACPComplete = true
		for _, lacpOk := range slaveStates {
			if !lacpOk {
				status.LACPComplete = false
				break
			}
		}
	} else {
		// For non-LACP bonds, consider complete if we have an active slave
		status.LACPComplete = (status.ActiveSlave != "" && status.SlaveCount > 0)
	}
	
	return status, nil
}

// IsBondInterface checks if an interface is a bond interface
func (im *InterfaceMonitor) IsBondInterface(interfaceName string) bool {
	bondPath := fmt.Sprintf("/proc/net/bonding/%s", interfaceName)
	_, err := os.Stat(bondPath)
	return err == nil
}

// isInterfaceTypeMonitored checks if an interface type should be monitored
func (im *InterfaceMonitor) isInterfaceTypeMonitored(interfaceName string) bool {
	interfaceType := im.getInterfaceType(interfaceName)
	
	for _, monitoredType := range im.interfaceTypes {
		if interfaceType == monitoredType {
			return true
		}
	}
	
	return false
}

// getInterfaceType determines the type of network interface
func (im *InterfaceMonitor) getInterfaceType(interfaceName string) InterfaceType {
	// Check if it's a bond interface
	if im.IsBondInterface(interfaceName) {
		return Bond
	}
	
	// Check wireless
	wirelessPath := fmt.Sprintf("/sys/class/net/%s/wireless", interfaceName)
	if _, err := os.Stat(wirelessPath); err == nil {
		return Wireless
	}
	
	// Check if it's a tunnel interface
	if strings.HasPrefix(interfaceName, "tun") || strings.HasPrefix(interfaceName, "tap") {
		return Tunnel
	}
	
	// Default to ethernet for physical interfaces
	if strings.HasPrefix(interfaceName, "eth") || strings.HasPrefix(interfaceName, "en") {
		return Ethernet
	}
	
	return Other
}
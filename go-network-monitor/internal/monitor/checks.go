package monitor

import (
	"fmt"
	"net"

	"github.com/samsyeung/network_startup_monitor_service/go-network-monitor/internal/system"
)

// checkNetworkServices checks the status of network services
func (m *Monitor) checkNetworkServices(enabledServices []string) bool {
	if len(enabledServices) == 0 {
		m.logger.Log("Network services: NONE FOUND")
		return true // Don't block if no services to check
	}
	
	if m.systemd == nil {
		m.logger.Log("Network services: SYSTEMD NOT AVAILABLE")
		return true // Don't block if systemd unavailable
	}
	
	serviceStatuses, err := m.systemd.CheckServicesStatus(enabledServices)
	if err != nil {
		m.logger.Logf("Network services: ERROR - %v", err)
		return false
	}
	
	activeCount := 0
	failedCount := 0
	
	for _, service := range enabledServices {
		if status, exists := serviceStatuses[service]; exists {
			m.logger.Log(status.String())
			
			if status.IsReady() {
				activeCount++
			} else if status.IsServiceFailed() || status.IsServiceStarting() {
				failedCount++
			}
		}
	}
	
	allReady := (failedCount == 0 && activeCount > 0)
	
	if allReady {
		m.logger.Logf("Network services: ALL READY (%d active)", activeCount)
	} else {
		m.logger.Logf("Network services: %d NOT READY, %d ready", failedCount, activeCount)
	}
	
	return allReady
}

// checkNetworkInterfaces checks all network interfaces
func (m *Monitor) checkNetworkInterfaces() bool {
	interfaces, err := m.ifaceMonitor.GetActiveInterfaces()
	if err != nil {
		m.logger.Logf("Failed to get interfaces: %v", err)
		return false
	}
	
	if len(interfaces) == 0 {
		m.logger.Log("No network interfaces found")
		return false
	}
	
	allUp := true
	
	for _, iface := range interfaces {
		status, err := m.ifaceMonitor.CheckInterfaceStatus(iface)
		if err != nil {
			m.logger.Logf("Interface %s: ERROR - %v", iface, err)
			allUp = false
			continue
		}
		
		carrierStatus := "DOWN"
		if status.Carrier {
			carrierStatus = "UP"
		}
		
		m.logger.Logf("Interface %s: carrier=%s, operstate=%s", 
			status.Name, carrierStatus, status.OperState)
		
		if !status.Carrier {
			allUp = false
		}
		
		// Check bond status if it's a bond interface
		if m.ifaceMonitor.IsBondInterface(iface) {
			bondStatus, err := m.ifaceMonitor.CheckBondStatus(iface)
			if err != nil {
				m.logger.Logf("Bond %s: ERROR - %v", iface, err)
				allUp = false
			} else {
				m.logger.Logf("Bond %s: mode=%s, mii_status=%s, active_slave=%s, slaves=%d/%d",
					bondStatus.Name, bondStatus.Mode, bondStatus.MIIStatus,
					bondStatus.ActiveSlave, bondStatus.SlaveCount, bondStatus.TotalSlaves)
				
				if bondStatus.LACPComplete {
					m.logger.Logf("Bond %s: LACP negotiation complete", bondStatus.Name)
					m.logger.Logf("Bond %s: HEALTHY", bondStatus.Name)
				} else {
					m.logger.Logf("Bond %s: LACP negotiation incomplete", bondStatus.Name)
					allUp = false
				}
			}
		}
	}
	
	return allUp
}

// checkGatewayConnectivity tests gateway reachability
func (m *Monitor) checkGatewayConnectivity() bool {
	gateway, err := m.connectivity.GetDefaultGateway()
	if err != nil {
		m.logger.Logf("Gateway: ERROR - %v", err)
		return false
	}
	
	err = m.connectivity.CheckGatewayReachability(gateway)
	if err != nil {
		m.logger.Logf("Gateway %s: NOT REACHABLE - %v", gateway, err)
		return false
	}
	
	m.logger.Logf("Gateway %s: REACHABLE (%s timeout)", gateway, m.config.PingTimeout)
	return true
}

// checkDNSResolution tests DNS resolution
func (m *Monitor) checkDNSResolution() bool {
	err := m.connectivity.CheckDNSResolution(m.config.ResolverHostname)
	if err != nil {
		m.logger.Logf("DNS resolution for %s: FAILED (%s timeout) - %v", 
			m.config.ResolverHostname, m.config.DNSTimeout, err)
		return false
	}
	
	m.logger.Logf("DNS resolution for %s: SUCCESS (%s timeout)", 
		m.config.ResolverHostname, m.config.DNSTimeout)
	return true
}

// checkNetworkManagerConnectivity checks NetworkManager connectivity
func (m *Monitor) checkNetworkManagerConnectivity() bool {
	connectivity, err := m.connectivity.CheckNetworkManagerConnectivity()
	if err != nil {
		m.logger.Logf("NetworkManager connectivity: SERVICE NOT AVAILABLE - %v", err)
		return true // Don't block if service unavailable
	}
	
	m.logger.Logf("NetworkManager connectivity: %s", connectivity)
	return connectivity == "full"
}

// checkARPTable validates ARP table entries
func (m *Monitor) checkARPTable() bool {
	m.logger.Log("--- ARP Table Status ---")
	
	interfaces, err := m.ifaceMonitor.GetActiveInterfaces()
	if err != nil {
		m.logger.Logf("ARP table: ERROR getting interfaces - %v", err)
		return false
	}
	
	if len(interfaces) == 0 {
		m.logger.Log("ARP table: No interfaces to check")
		return false
	}
	
	gateway, err := m.connectivity.GetDefaultGateway()
	if err != nil {
		gateway = nil // Continue without gateway check
	}
	
	arpStatus, err := m.arpMonitor.CheckARPTable(interfaces, gateway)
	if err != nil {
		m.logger.Logf("ARP table: ERROR - %v", err)
		return false
	}
	
	// Log per-interface ARP counts
	for _, iface := range interfaces {
		count := arpStatus.InterfaceEntries[iface]
		if gateway != nil && arpStatus.GatewayResolved && arpStatus.GatewayMAC != nil {
			m.logger.Logf("ARP table %s: %d entries (gateway %s -> %s)", 
				iface, count, gateway, arpStatus.GatewayMAC)
		} else {
			m.logger.Logf("ARP table %s: %d entries", iface, count)
		}
	}
	
	m.logger.Logf("ARP table total: %d entries", arpStatus.TotalEntries)
	
	if gateway != nil {
		if arpStatus.GatewayResolved {
			m.logger.Logf("ARP table gateway: %s RESOLVED", gateway)
			return true
		} else {
			m.logger.Logf("ARP table gateway: %s NOT RESOLVED", gateway)
			return false
		}
	} else {
		if arpStatus.TotalEntries > 0 {
			m.logger.Log("ARP table: POPULATED (no gateway to check)")
			return true
		} else {
			m.logger.Log("ARP table: EMPTY")
			return false
		}
	}
}

// checkRoutingTable validates routing table convergence
func (m *Monitor) checkRoutingTable() bool {
	m.logger.Log("--- Routing Table Status ---")
	
	routeStatus, err := m.routeMonitor.CheckRoutingTable()
	if err != nil {
		m.logger.Logf("Routing table: ERROR - %v", err)
		return false
	}
	
	m.logger.Logf("Routing table: %d total routes", routeStatus.TotalRoutes)
	m.logger.Logf("Routing table: %d default routes", routeStatus.DefaultRoutes)
	m.logger.Logf("Routing table: %d network routes", routeStatus.NetworkRoutes)
	m.logger.Logf("Routing table: %d host routes", routeStatus.HostRoutes)
	
	if routeStatus.HasDefaultRoute {
		// Get detailed default route information
		defaultRoutes, err := m.routeMonitor.GetDefaultRoutes()
		if err == nil {
			for _, route := range defaultRoutes {
				m.logger.Logf("Default route: %s", route.String())
			}
		}
		
		m.logger.Log("*** ROUTING TABLE HAS DEFAULT ROUTE ***")
		return true
	} else {
		m.logger.Log("Routing table: NO DEFAULT ROUTE")
		return false
	}
}

// updateStates updates internal state and logs transitions
func (m *Monitor) updateStates(allUp, gwReachable, servicesReady, dnsWorking, nmConnectivity, arpValid, routingValid bool) {
	// Interface state transitions
	if allUp && !m.allInterfacesUp {
		m.logger.Log("*** ALL INTERFACES ARE NOW UP ***")
		m.allInterfacesUp = true
	} else if !allUp && m.allInterfacesUp {
		m.logger.Log("*** SOME INTERFACES ARE DOWN ***")
		m.allInterfacesUp = false
	}
	
	// Gateway state transitions
	if gwReachable && !m.gatewayReachable {
		m.logger.Log("*** GATEWAY IS NOW REACHABLE ***")
		m.gatewayReachable = true
	} else if !gwReachable && m.gatewayReachable {
		m.logger.Log("*** GATEWAY IS NO LONGER REACHABLE ***")
		m.gatewayReachable = false
	}
	
	// Services state transitions
	if servicesReady && !m.servicesReady {
		m.logger.Log("*** NETWORK SERVICES ARE NOW READY ***")
		m.servicesReady = true
	} else if !servicesReady && m.servicesReady {
		m.logger.Log("*** NETWORK SERVICES NO LONGER READY ***")
		m.servicesReady = false
	}
	
	// DNS state transitions
	if dnsWorking && !m.dnsWorking {
		m.logger.Log("*** DNS RESOLUTION IS NOW WORKING ***")
		m.dnsWorking = true
	} else if !dnsWorking && m.dnsWorking {
		m.logger.Log("*** DNS RESOLUTION NO LONGER WORKING ***")
		m.dnsWorking = false
	}
	
	// NetworkManager connectivity state transitions
	if nmConnectivity && !m.nmConnectivityFull {
		m.logger.Log("*** NETWORKMANAGER CONNECTIVITY IS NOW FULL ***")
		m.nmConnectivityFull = true
	} else if !nmConnectivity && m.nmConnectivityFull {
		m.logger.Log("*** NETWORKMANAGER CONNECTIVITY NO LONGER FULL ***")
		m.nmConnectivityFull = false
	}
	
	// ARP table state transitions
	if arpValid && !m.arpTableValid {
		m.logger.Log("*** ARP TABLE IS NOW VALID ***")
		m.arpTableValid = true
	} else if !arpValid && m.arpTableValid {
		m.logger.Log("*** ARP TABLE NO LONGER VALID ***")
		m.arpTableValid = false
	}
	
	// Routing table state transitions
	if routingValid && !m.routingTableValid {
		m.logger.Log("*** ROUTING TABLE IS NOW VALID ***")
		m.routingTableValid = true
	} else if !routingValid && m.routingTableValid {
		m.logger.Log("*** ROUTING TABLE NO LONGER VALID ***")
		m.routingTableValid = false
	}
}
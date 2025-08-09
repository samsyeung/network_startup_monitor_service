package network

import (
	"fmt"
	"net"
	
	"github.com/vishvananda/netlink"
)

// RouteType represents different types of routes
type RouteType string

const (
	DefaultRoute  RouteType = "default"
	NetworkRoute  RouteType = "network"
	HostRoute     RouteType = "host"
	InterfaceRoute RouteType = "interface"
)

// RouteEntry represents a routing table entry
type RouteEntry struct {
	Destination   *net.IPNet
	Gateway       net.IP
	Interface     string
	Metric        int
	Type          RouteType
}

// RoutingTableStatus represents the status of the routing table
type RoutingTableStatus struct {
	TotalRoutes    int
	DefaultRoutes  int
	NetworkRoutes  int
	HostRoutes     int
	HasDefaultRoute bool
	DefaultGateway  net.IP
	DefaultInterface string
}

// RoutingMonitor handles routing table monitoring
type RoutingMonitor struct{}

// NewRoutingMonitor creates a new routing monitor
func NewRoutingMonitor() *RoutingMonitor {
	return &RoutingMonitor{}
}

// CheckRoutingTable analyzes the routing table
func (rm *RoutingMonitor) CheckRoutingTable() (*RoutingTableStatus, error) {
	routes, err := netlink.RouteList(nil, netlink.FAMILY_V4)
	if err != nil {
		return nil, fmt.Errorf("failed to get routing table: %w", err)
	}
	
	status := &RoutingTableStatus{}
	
	for _, route := range routes {
		status.TotalRoutes++
		
		// Categorize route type
		if route.Dst == nil {
			// Default route (0.0.0.0/0)
			status.DefaultRoutes++
			status.HasDefaultRoute = true
			status.DefaultGateway = route.Gw
			
			if route.LinkIndex > 0 {
				if link, err := netlink.LinkByIndex(route.LinkIndex); err == nil {
					status.DefaultInterface = link.Attrs().Name
				}
			}
		} else {
			// Check if it's a host route (/32)
			ones, _ := route.Dst.Mask.Size()
			if ones == 32 {
				status.HostRoutes++
			} else {
				status.NetworkRoutes++
			}
		}
	}
	
	return status, nil
}

// GetDefaultRoutes returns all default routes
func (rm *RoutingMonitor) GetDefaultRoutes() ([]RouteEntry, error) {
	routes, err := netlink.RouteList(nil, netlink.FAMILY_V4)
	if err != nil {
		return nil, fmt.Errorf("failed to get routes: %w", err)
	}
	
	var defaultRoutes []RouteEntry
	for _, route := range routes {
		if route.Dst == nil { // Default route
			entry := RouteEntry{
				Gateway: route.Gw,
				Metric:  route.Priority,
				Type:    DefaultRoute,
			}
			
			if route.LinkIndex > 0 {
				if link, err := netlink.LinkByIndex(route.LinkIndex); err == nil {
					entry.Interface = link.Attrs().Name
				}
			}
			
			defaultRoutes = append(defaultRoutes, entry)
		}
	}
	
	return defaultRoutes, nil
}

// GetAllRoutes returns all routes in the routing table
func (rm *RoutingMonitor) GetAllRoutes() ([]RouteEntry, error) {
	routes, err := netlink.RouteList(nil, netlink.FAMILY_V4)
	if err != nil {
		return nil, fmt.Errorf("failed to get routes: %w", err)
	}
	
	var routeEntries []RouteEntry
	for _, route := range routes {
		entry := RouteEntry{
			Destination: route.Dst,
			Gateway:     route.Gw,
			Metric:      route.Priority,
		}
		
		// Determine route type
		if route.Dst == nil {
			entry.Type = DefaultRoute
		} else {
			ones, _ := route.Dst.Mask.Size()
			if ones == 32 {
				entry.Type = HostRoute
			} else {
				entry.Type = NetworkRoute
			}
		}
		
		// Get interface name
		if route.LinkIndex > 0 {
			if link, err := netlink.LinkByIndex(route.LinkIndex); err == nil {
				entry.Interface = link.Attrs().Name
			}
		}
		
		routeEntries = append(routeEntries, entry)
	}
	
	return routeEntries, nil
}

// String returns a string representation of a route entry
func (re *RouteEntry) String() string {
	var dest string
	if re.Destination == nil {
		dest = "default"
	} else {
		dest = re.Destination.String()
	}
	
	if re.Gateway != nil {
		if re.Metric > 0 {
			return fmt.Sprintf("%s via %s dev %s metric %d", dest, re.Gateway, re.Interface, re.Metric)
		} else {
			return fmt.Sprintf("%s via %s dev %s", dest, re.Gateway, re.Interface)
		}
	} else {
		return fmt.Sprintf("%s dev %s", dest, re.Interface)
	}
}
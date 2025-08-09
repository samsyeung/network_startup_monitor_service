package network

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"time"
	
	"github.com/vishvananda/netlink"
)

// ConnectivityChecker handles network connectivity tests
type ConnectivityChecker struct {
	pingTimeout time.Duration
	dnsTimeout  time.Duration
}

// NewConnectivityChecker creates a new connectivity checker
func NewConnectivityChecker(pingTimeout, dnsTimeout time.Duration) *ConnectivityChecker {
	return &ConnectivityChecker{
		pingTimeout: pingTimeout,
		dnsTimeout:  dnsTimeout,
	}
}

// GetDefaultGateway returns the default gateway IP address
func (cc *ConnectivityChecker) GetDefaultGateway() (net.IP, error) {
	routes, err := netlink.RouteList(nil, netlink.FAMILY_V4)
	if err != nil {
		return nil, fmt.Errorf("failed to list routes: %w", err)
	}
	
	for _, route := range routes {
		// Look for default route (destination 0.0.0.0/0)
		if route.Dst == nil && route.Gw != nil {
			return route.Gw, nil
		}
	}
	
	return nil, fmt.Errorf("no default gateway found")
}

// CheckGatewayReachability tests if the default gateway is reachable via ping
func (cc *ConnectivityChecker) CheckGatewayReachability(gateway net.IP) error {
	if gateway == nil {
		return fmt.Errorf("no gateway provided")
	}
	
	ctx, cancel := context.WithTimeout(context.Background(), cc.pingTimeout)
	defer cancel()
	
	// Use ping command with specific timeout
	cmd := exec.CommandContext(ctx, "ping", "-c", "1", "-W", "1", gateway.String())
	output, err := cmd.CombinedOutput()
	
	if err != nil {
		return fmt.Errorf("ping failed: %s", strings.TrimSpace(string(output)))
	}
	
	return nil
}

// CheckDNSResolution tests DNS resolution for a given hostname
func (cc *ConnectivityChecker) CheckDNSResolution(hostname string) error {
	if hostname == "" {
		return fmt.Errorf("no hostname provided")
	}
	
	ctx, cancel := context.WithTimeout(context.Background(), cc.dnsTimeout)
	defer cancel()
	
	resolver := &net.Resolver{}
	_, err := resolver.LookupHost(ctx, hostname)
	if err != nil {
		return fmt.Errorf("DNS resolution failed for %s: %w", hostname, err)
	}
	
	return nil
}

// CheckNetworkManagerConnectivity checks NetworkManager connectivity status
func (cc *ConnectivityChecker) CheckNetworkManagerConnectivity() (string, error) {
	// Check if NetworkManager is running
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	
	cmd := exec.CommandContext(ctx, "systemctl", "is-active", "NetworkManager")
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("NetworkManager is not running")
	}
	
	// Check if nmcli is available
	if _, err := exec.LookPath("nmcli"); err != nil {
		return "", fmt.Errorf("nmcli not available")
	}
	
	// Get connectivity status
	ctx, cancel = context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	
	cmd = exec.CommandContext(ctx, "nmcli", "networking", "connectivity")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to query NetworkManager connectivity: %w", err)
	}
	
	connectivity := strings.TrimSpace(string(output))
	return connectivity, nil
}

// IsNetworkManagerConnectivityFull checks if NetworkManager reports full connectivity
func (cc *ConnectivityChecker) IsNetworkManagerConnectivityFull() bool {
	connectivity, err := cc.CheckNetworkManagerConnectivity()
	if err != nil {
		return false // Consider as not blocking if service is unavailable
	}
	
	return connectivity == "full"
}
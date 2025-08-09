package system

import (
	"context"
	"fmt"
	"strings"
	"time"
	
	"github.com/coreos/go-systemd/v22/dbus"
)

// ServiceState represents the state of a systemd service
type ServiceState string

const (
	ServiceActive      ServiceState = "active"
	ServiceInactive    ServiceState = "inactive"
	ServiceFailed      ServiceState = "failed"
	ServiceActivating  ServiceState = "activating"
	ServiceDeactivating ServiceState = "deactivating"
	ServiceUnknown     ServiceState = "unknown"
)

// ServiceStatus represents the status of a systemd service
type ServiceStatus struct {
	Name        string
	ActiveState ServiceState
	LoadState   string
	SubState    string
	Available   bool
}

// SystemdMonitor handles systemd service monitoring
type SystemdMonitor struct {
	conn *dbus.Conn
}

// NewSystemdMonitor creates a new systemd monitor
func NewSystemdMonitor() (*SystemdMonitor, error) {
	conn, err := dbus.NewSystemdConnectionContext(context.Background())
	if err != nil {
		return nil, fmt.Errorf("failed to connect to systemd: %w", err)
	}
	
	return &SystemdMonitor{conn: conn}, nil
}

// Close closes the systemd connection
func (sm *SystemdMonitor) Close() {
	if sm.conn != nil {
		sm.conn.Close()
	}
}

// GetEnabledServices returns the list of enabled services from the given service list
func (sm *SystemdMonitor) GetEnabledServices(serviceNames []string) ([]string, error) {
	var enabledServices []string
	
	for _, serviceName := range serviceNames {
		unitStatus, err := sm.conn.GetUnitPropertiesContext(
			context.Background(),
			serviceName,
			"org.freedesktop.systemd1.Unit",
		)
		if err != nil {
			continue // Service not found, skip
		}
		
		loadState, ok := unitStatus["LoadState"].(string)
		if !ok {
			continue
		}
		
		// Check if service is loaded and enabled
		switch loadState {
		case "loaded", "enabled", "enabled-runtime", "static", "generated", "indirect":
			enabledServices = append(enabledServices, serviceName)
		}
	}
	
	return enabledServices, nil
}

// CheckServicesStatus checks the status of multiple services in batch
func (sm *SystemdMonitor) CheckServicesStatus(serviceNames []string) (map[string]*ServiceStatus, error) {
	results := make(map[string]*ServiceStatus)
	
	// Get all service statuses in parallel using goroutines
	type result struct {
		name   string
		status *ServiceStatus
		err    error
	}
	
	resultChan := make(chan result, len(serviceNames))
	
	for _, serviceName := range serviceNames {
		go func(name string) {
			status, err := sm.checkSingleServiceStatus(name)
			resultChan <- result{name: name, status: status, err: err}
		}(serviceName)
	}
	
	// Collect results
	for i := 0; i < len(serviceNames); i++ {
		res := <-resultChan
		if res.err == nil {
			results[res.name] = res.status
		}
	}
	
	return results, nil
}

// CheckServiceStatus checks the status of a single service
func (sm *SystemdMonitor) CheckServiceStatus(serviceName string) (*ServiceStatus, error) {
	return sm.checkSingleServiceStatus(serviceName)
}

// checkSingleServiceStatus performs the actual status check for a single service
func (sm *SystemdMonitor) checkSingleServiceStatus(serviceName string) (*ServiceStatus, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	
	unitStatus, err := sm.conn.GetUnitPropertiesContext(
		ctx,
		serviceName,
		"org.freedesktop.systemd1.Unit",
	)
	if err != nil {
		return &ServiceStatus{
			Name:        serviceName,
			ActiveState: ServiceUnknown,
			Available:   false,
		}, nil
	}
	
	status := &ServiceStatus{
		Name:      serviceName,
		Available: true,
	}
	
	// Extract ActiveState
	if activeState, ok := unitStatus["ActiveState"].(string); ok {
		status.ActiveState = ServiceState(activeState)
	} else {
		status.ActiveState = ServiceUnknown
	}
	
	// Extract LoadState
	if loadState, ok := unitStatus["LoadState"].(string); ok {
		status.LoadState = loadState
	}
	
	// Extract SubState
	if subState, ok := unitStatus["SubState"].(string); ok {
		status.SubState = subState
	}
	
	return status, nil
}

// IsServiceReady determines if a service is in a ready state
func (ss *ServiceStatus) IsReady() bool {
	return ss.ActiveState == ServiceActive
}

// IsServiceFailed determines if a service is in a failed state
func (ss *ServiceStatus) IsServiceFailed() bool {
	return ss.ActiveState == ServiceFailed
}

// IsServiceStarting determines if a service is starting
func (ss *ServiceStatus) IsServiceStarting() bool {
	return ss.ActiveState == ServiceActivating
}

// String returns a string representation of the service status
func (ss *ServiceStatus) String() string {
	if !ss.Available {
		return fmt.Sprintf("%s: NOT FOUND", ss.Name)
	}
	
	var state string
	switch ss.ActiveState {
	case ServiceActive:
		state = fmt.Sprintf("ACTIVE (%s)", ss.SubState)
	case ServiceInactive:
		state = fmt.Sprintf("INACTIVE (%s) - skipping", ss.SubState)
	case ServiceFailed:
		state = fmt.Sprintf("FAILED (%s)", ss.SubState)
	case ServiceActivating:
		state = fmt.Sprintf("STARTING (%s)", ss.SubState)
	case ServiceDeactivating:
		state = fmt.Sprintf("STOPPING (%s)", ss.SubState)
	default:
		state = fmt.Sprintf("UNKNOWN STATE (%s/%s)", ss.ActiveState, ss.SubState)
	}
	
	return fmt.Sprintf("%s: %s", ss.Name, state)
}
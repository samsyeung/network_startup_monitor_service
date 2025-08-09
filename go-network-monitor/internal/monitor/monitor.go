package monitor

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"
	
	"github.com/samsyeung/network_startup_monitor_service/go-network-monitor/internal/config"
	"github.com/samsyeung/network_startup_monitor_service/go-network-monitor/internal/logger"
	"github.com/samsyeung/network_startup_monitor_service/go-network-monitor/internal/network"
	"github.com/samsyeung/network_startup_monitor_service/go-network-monitor/internal/system"
)

// Monitor represents the main network monitoring service
type Monitor struct {
	config      *config.Config
	logger      *logger.Logger
	ifaceMonitor *network.InterfaceMonitor
	connectivity *network.ConnectivityChecker
	arpMonitor   *network.ARPMonitor
	routeMonitor *network.RoutingMonitor
	systemd      *system.SystemdMonitor
	lockFile     *os.File
	
	// State tracking
	allInterfacesUp    bool
	gatewayReachable   bool
	servicesReady      bool
	dnsWorking         bool
	nmConnectivityFull bool
	arpTableValid      bool
	routingTableValid  bool
	
	networkCompleteTime time.Time
	startTime          time.Time
}

// New creates a new monitor instance
func New(cfg *config.Config) (*Monitor, error) {
	// Create logger
	log, err := logger.New(cfg.LogFile)
	if err != nil {
		return nil, fmt.Errorf("failed to create logger: %w", err)
	}
	
	// Create systemd monitor
	systemdMonitor, err := system.NewSystemdMonitor()
	if err != nil {
		log.Log("Warning: Failed to connect to systemd, service monitoring disabled")
		systemdMonitor = nil
	}
	
	monitor := &Monitor{
		config:       cfg,
		logger:       log,
		ifaceMonitor: network.NewInterfaceMonitor(cfg.InterfaceTypes),
		connectivity: network.NewConnectivityChecker(cfg.PingTimeout, cfg.DNSTimeout),
		arpMonitor:   network.NewARPMonitor(),
		routeMonitor: network.NewRoutingMonitor(),
		systemd:      systemdMonitor,
		startTime:    time.Now(),
	}
	
	return monitor, nil
}

// Run starts the monitoring loop
func (m *Monitor) Run() error {
	// Acquire lock file
	if err := m.acquireLock(); err != nil {
		return err
	}
	defer m.releaseLock()
	
	// Log startup banner
	mode := "MONITORING"
	if m.config.BlockingMode {
		mode = "BLOCKING"
	}
	
	m.logger.Banner(
		os.Getpid(),
		mode,
		m.config.TotalTimeout,
		m.config.RunAfterSuccess,
		m.config.SleepInterval,
		m.config.InterfaceTypes,
		m.config.ResolverHostname,
		m.config.PingTimeout,
		m.config.DNSTimeout,
	)
	
	// Set up signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)
	
	// Get enabled services at startup
	var enabledServices []string
	if m.systemd != nil {
		services, err := m.systemd.GetEnabledServices(m.config.NetworkServices)
		if err != nil {
			m.logger.Logf("Warning: Failed to get enabled services: %v", err)
		} else {
			enabledServices = services
			for _, service := range services {
				m.logger.Logf("Service %s: found and enabled - will monitor", service)
			}
		}
	}
	
	if len(enabledServices) == 0 {
		m.logger.Log("Network services: NONE FOUND")
	}
	
	m.logger.Logf("Network monitor starting (%s mode - timeout: %s)", mode, m.config.TotalTimeout)
	
	// Start monitoring loop
	ticker := time.NewTicker(m.config.SleepInterval)
	defer ticker.Stop()
	
	totalTimeout := time.NewTimer(m.config.TotalTimeout)
	defer totalTimeout.Stop()
	
	for {
		select {
		case <-sigChan:
			m.logger.Log("Received signal, shutting down")
			return nil
			
		case <-totalTimeout.C:
			m.logger.Logf("*** TOTAL TIMEOUT REACHED (%s) - EXITING ***", m.config.TotalTimeout)
			return nil
			
		case <-ticker.C:
			if err := m.performChecks(enabledServices); err != nil {
				m.logger.Logf("Error during checks: %v", err)
				continue
			}
			
			// Check if we should exit
			if m.shouldExit() {
				return nil
			}
		}
	}
}

// performChecks performs all network status checks
func (m *Monitor) performChecks(enabledServices []string) error {
	m.logger.Log("=== Network Status Check ===")
	
	// Check services
	currentServicesReady := m.checkNetworkServices(enabledServices)
	
	// Check interfaces
	currentAllInterfacesUp := m.checkNetworkInterfaces()
	
	// Check gateway connectivity
	currentGatewayReachable := m.checkGatewayConnectivity()
	
	// Check DNS resolution
	currentDNSWorking := m.checkDNSResolution()
	
	// Check NetworkManager connectivity
	currentNMConnectivity := m.checkNetworkManagerConnectivity()
	
	// Check ARP table
	currentARPTableValid := m.checkARPTable()
	
	// Check routing table
	currentRoutingTableValid := m.checkRoutingTable()
	
	// Update state and log transitions
	m.updateStates(
		currentAllInterfacesUp,
		currentGatewayReachable,
		currentServicesReady,
		currentDNSWorking,
		currentNMConnectivity,
		currentARPTableValid,
		currentRoutingTableValid,
	)
	
	return nil
}

// shouldExit determines if the monitor should exit
func (m *Monitor) shouldExit() bool {
	allReady := m.allInterfacesUp && m.gatewayReachable && m.servicesReady &&
		m.dnsWorking && m.nmConnectivityFull && m.arpTableValid && m.routingTableValid
	
	if allReady {
		if m.networkCompleteTime.IsZero() {
			m.networkCompleteTime = time.Now()
			if m.config.BlockingMode {
				m.logger.Log("*** NETWORK IS READY - UNBLOCKING BOOT PROCESS ***")
				return true
			} else {
				m.logger.Logf("*** NETWORK SETUP COMPLETE (services + interfaces + gateway + DNS + NetworkManager connectivity + ARP table + routing table) *** (will exit in %s)", m.config.RunAfterSuccess)
			}
		} else if m.config.RunAfterSuccess > 0 {
			elapsed := time.Since(m.networkCompleteTime)
			if elapsed >= m.config.RunAfterSuccess {
				m.logger.Logf("*** RUN-AFTER-SUCCESS PERIOD COMPLETE (%s) - EXITING ***", m.config.RunAfterSuccess)
				return true
			}
		}
	} else {
		if !m.networkCompleteTime.IsZero() {
			if m.config.BlockingMode {
				m.logger.Log("*** NETWORK NO LONGER COMPLETE - CONTINUING TO BLOCK ***")
			} else {
				m.logger.Log("*** NETWORK NO LONGER COMPLETE - RESETTING SUCCESS TIMER ***")
			}
			m.networkCompleteTime = time.Time{}
		}
	}
	
	return false
}

// Close cleans up resources
func (m *Monitor) Close() error {
	if m.systemd != nil {
		m.systemd.Close()
	}
	if m.logger != nil {
		m.logger.Close()
	}
	m.releaseLock()
	return nil
}

// acquireLock acquires the lock file
func (m *Monitor) acquireLock() error {
	// Check if lock file already exists
	if _, err := os.Stat(m.config.LockFile); err == nil {
		return fmt.Errorf("network monitor already running (lockfile exists)")
	}
	
	// Create lock file
	file, err := os.Create(m.config.LockFile)
	if err != nil {
		return fmt.Errorf("failed to create lock file: %w", err)
	}
	
	// Write PID to lock file
	_, err = fmt.Fprintf(file, "%d\n", os.Getpid())
	if err != nil {
		file.Close()
		os.Remove(m.config.LockFile)
		return fmt.Errorf("failed to write PID to lock file: %w", err)
	}
	
	m.lockFile = file
	return nil
}

// releaseLock releases the lock file
func (m *Monitor) releaseLock() {
	if m.lockFile != nil {
		m.lockFile.Close()
		os.Remove(m.config.LockFile)
		m.lockFile = nil
	}
}
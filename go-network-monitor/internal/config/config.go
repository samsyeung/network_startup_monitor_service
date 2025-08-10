package config

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds all configuration options for the network monitor
type Config struct {
	// Timeouts and intervals
	TotalTimeout     time.Duration
	RunAfterSuccess  time.Duration
	SleepInterval    time.Duration
	PingTimeout      time.Duration
	DNSTimeout       time.Duration
	
	// Operating mode
	BlockingMode     bool
	
	// Interface monitoring
	InterfaceTypes      []string
	RequiredInterfaces  []string  // Specific interfaces that must be up (empty = any interface sufficient)
	
	// Network services
	NetworkServices  []string
	
	// DNS resolution
	ResolverHostname string
	
	// File paths
	LogFile          string
	LockFile         string
}

// DefaultConfig returns a configuration with default values
func DefaultConfig() *Config {
	logFile := "/var/log/network_startup_monitor.log"
	lockFile := "/var/run/network_monitor.lock"
	
	// Set log file location based on user privileges (like bash script)
	if os.Geteuid() != 0 {
		// Non-root user - use home directory or temp location
		if home := os.Getenv("HOME"); home != "" {
			if info, err := os.Stat(home); err == nil && info.IsDir() {
				logFile = home + "/network_startup_monitor.log"
				lockFile = home + "/network_monitor.lock"
			}
		} else {
			uid := os.Getuid()
			logFile = fmt.Sprintf("/tmp/network_startup_monitor_%d.log", uid)
			lockFile = fmt.Sprintf("/tmp/network_monitor_%d.lock", uid)
		}
	}
	
	return &Config{
		TotalTimeout:       15 * time.Minute,
		RunAfterSuccess:    1 * time.Minute,  // Updated to match bash script v0.6.1
		SleepInterval:      1 * time.Second,
		PingTimeout:        1 * time.Second,
		DNSTimeout:         1 * time.Second,  // Updated to match bash script v0.6.1
		BlockingMode:       false,
		InterfaceTypes:     []string{"ethernet", "bond"},
		RequiredInterfaces: []string{},  // Empty = any interface sufficient
		NetworkServices: []string{
			"systemd-networkd.service",
			"systemd-networkd-wait-online.service",
			"NetworkManager.service",
			"NetworkManager-wait-online.service",
			"systemd-resolved.service",
			"networking.service",
			"dhcpcd.service",
			"wpa_supplicant.service",
		},
		ResolverHostname: "google.com",
		LogFile:         logFile,
		LockFile:        lockFile,
	}
}

// LoadFromEnv loads configuration from environment variables
func (c *Config) LoadFromEnv() {
	if val := os.Getenv("TOTAL_TIMEOUT"); val != "" {
		if timeout, err := strconv.Atoi(val); err == nil {
			c.TotalTimeout = time.Duration(timeout) * time.Second
		}
	}
	
	if val := os.Getenv("RUN_AFTER_SUCCESS"); val != "" {
		if timeout, err := strconv.Atoi(val); err == nil {
			c.RunAfterSuccess = time.Duration(timeout) * time.Second
		}
	}
	
	if val := os.Getenv("SLEEP_INTERVAL"); val != "" {
		// Try parsing as duration first (e.g., "1.5s", "500ms")
		if duration, err := time.ParseDuration(val); err == nil {
			c.SleepInterval = duration
		} else if interval, err := strconv.ParseFloat(val, 64); err == nil {
			// Fall back to parsing as float seconds for backward compatibility
			c.SleepInterval = time.Duration(interval * float64(time.Second))
		}
	}
	
	if val := os.Getenv("PING_TIMEOUT"); val != "" {
		if timeout, err := strconv.Atoi(val); err == nil {
			c.PingTimeout = time.Duration(timeout) * time.Second
		}
	}
	
	if val := os.Getenv("DNS_TIMEOUT"); val != "" {
		if timeout, err := strconv.Atoi(val); err == nil {
			c.DNSTimeout = time.Duration(timeout) * time.Second
		}
	}
	
	if val := os.Getenv("INTERFACE_TYPES"); val != "" {
		c.InterfaceTypes = strings.Fields(val)
	}
	
	if val := os.Getenv("REQUIRED_INTERFACES"); val != "" {
		c.RequiredInterfaces = strings.Fields(val)
	}
	
	if val := os.Getenv("NETWORK_SERVICES"); val != "" {
		c.NetworkServices = strings.Fields(val)
	}
	
	if val := os.Getenv("RESOLVER_HOSTNAME"); val != "" {
		c.ResolverHostname = val
	}
}

// ParseFlags parses command line flags
func (c *Config) ParseFlags() {
	// Operating mode
	blocking := flag.Bool("blocking", false, "Exit immediately when network is ready (default: continuous monitoring)")
	
	// Interface configuration
	requiredInterfaces := flag.String("required-interfaces", "", "Space-separated interfaces that must be up (default: any interface sufficient)")
	interfaceTypes := flag.String("interface-types", "", "Space-separated interface types to monitor (default: \"ethernet bond\")")
	
	// Timeouts
	totalTimeout := flag.Int("total-timeout", 0, "Maximum runtime in seconds (default: 900)")
	runAfterSuccess := flag.Int("run-after-success", 0, "Time to run after network ready in monitoring mode (default: 60)")
	sleepInterval := flag.String("sleep-interval", "", "Check frequency (e.g., '1s', '1.5s', '500ms') (default: 1s)")
	pingTimeout := flag.Int("ping-timeout", 0, "Gateway ping timeout in seconds (default: 1)")
	dnsTimeout := flag.Int("dns-timeout", 0, "DNS resolution timeout in seconds (default: 1)")
	
	// Network configuration
	networkServices := flag.String("network-services", "", "Space-separated network services to monitor")
	resolverHostname := flag.String("resolver-hostname", "", "Hostname for DNS resolution test (default: google.com)")
	
	// Help
	help := flag.Bool("help", false, "Show this help message")
	helpShort := flag.Bool("h", false, "Show this help message")
	
	flag.Parse()
	
	// Show help if requested
	if *help || *helpShort {
		fmt.Println("Usage: network-monitor [OPTIONS]")
		fmt.Println("")
		fmt.Println("Network startup monitor service for Linux systems")
		fmt.Println("")
		fmt.Println("OPTIONS:")
		flag.PrintDefaults()
		fmt.Println("")
		fmt.Println("Examples:")
		fmt.Println("  network-monitor                                       # Monitor any interface, continuous mode")
		fmt.Println("  network-monitor -blocking                            # Exit when network ready")
		fmt.Println("  network-monitor -required-interfaces \"eth0 eth1\"     # Require specific interfaces")
		fmt.Println("  network-monitor -total-timeout 300 -sleep-interval 1.5s # Custom timeouts")
		fmt.Println("  network-monitor -interface-types \"ethernet bond vlan\" # Monitor additional interface types")
		os.Exit(0)
	}
	
	// Apply flag values
	c.BlockingMode = *blocking
	if c.BlockingMode {
		c.RunAfterSuccess = 0
	}
	
	if *requiredInterfaces != "" {
		c.RequiredInterfaces = strings.Fields(*requiredInterfaces)
	}
	
	if *interfaceTypes != "" {
		c.InterfaceTypes = strings.Fields(*interfaceTypes)
	}
	
	if *totalTimeout > 0 {
		c.TotalTimeout = time.Duration(*totalTimeout) * time.Second
	}
	
	if *runAfterSuccess > 0 {
		c.RunAfterSuccess = time.Duration(*runAfterSuccess) * time.Second
	}
	
	if *sleepInterval != "" {
		// Try parsing as duration first (e.g., "1.5s", "500ms")
		if duration, err := time.ParseDuration(*sleepInterval); err == nil {
			c.SleepInterval = duration
		} else if interval, err := strconv.ParseFloat(*sleepInterval, 64); err == nil {
			// Fall back to parsing as float seconds for backward compatibility
			c.SleepInterval = time.Duration(interval * float64(time.Second))
		}
	}
	
	if *pingTimeout > 0 {
		c.PingTimeout = time.Duration(*pingTimeout) * time.Second
	}
	
	if *dnsTimeout > 0 {
		c.DNSTimeout = time.Duration(*dnsTimeout) * time.Second
	}
	
	if *networkServices != "" {
		c.NetworkServices = strings.Fields(*networkServices)
	}
	
	if *resolverHostname != "" {
		c.ResolverHostname = *resolverHostname
	}
}
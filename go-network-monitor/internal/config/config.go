package config

import (
	"flag"
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
	InterfaceTypes   []string
	
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
	return &Config{
		TotalTimeout:     15 * time.Minute,
		RunAfterSuccess:  1 * time.Minute,
		SleepInterval:    1 * time.Second,
		PingTimeout:      1 * time.Second,
		DNSTimeout:       3 * time.Second,
		BlockingMode:     false,
		InterfaceTypes:   []string{"ethernet", "bond"},
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
		LogFile:         "/var/log/network_startup_monitor.log",
		LockFile:        "/var/run/network_monitor.lock",
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
		if interval, err := strconv.Atoi(val); err == nil {
			c.SleepInterval = time.Duration(interval) * time.Second
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
	
	if val := os.Getenv("NETWORK_SERVICES"); val != "" {
		c.NetworkServices = strings.Fields(val)
	}
	
	if val := os.Getenv("RESOLVER_HOSTNAME"); val != "" {
		c.ResolverHostname = val
	}
}

// ParseFlags parses command line flags
func (c *Config) ParseFlags() {
	blocking := flag.Bool("blocking", false, "Run in blocking mode (exit immediately when network is ready)")
	flag.Parse()
	
	c.BlockingMode = *blocking
	if c.BlockingMode {
		c.RunAfterSuccess = 0
	}
}
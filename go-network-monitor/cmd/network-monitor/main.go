package main

import (
	"fmt"
	"log"
	"os"
	
	"github.com/samsyeung/network_startup_monitor_service/go-network-monitor/internal/config"
	"github.com/samsyeung/network_startup_monitor_service/go-network-monitor/internal/monitor"
)

func main() {
	// Check if running as root
	if os.Geteuid() != 0 {
		fmt.Fprintf(os.Stderr, "Error: Network monitor must be run as root\n")
		os.Exit(1)
	}
	
	// Load configuration
	cfg := config.DefaultConfig()
	cfg.LoadFromEnv()
	cfg.ParseFlags()
	
	// Create and run monitor
	mon, err := monitor.New(cfg)
	if err != nil {
		log.Fatalf("Failed to create monitor: %v", err)
	}
	defer mon.Close()
	
	if err := mon.Run(); err != nil {
		log.Fatalf("Monitor failed: %v", err)
	}
}
package main

import (
	"fmt"
	"log"
	"os"
	
	"github.com/samsyeung/network_startup_monitor_service/go-network-monitor/internal/config"
	"github.com/samsyeung/network_startup_monitor_service/go-network-monitor/internal/monitor"
)

func main() {
	// Load configuration (supports both root and non-root users now)
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
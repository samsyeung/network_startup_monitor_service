# Go Network Monitor Makefile

BINARY_NAME=network-monitor
INSTALL_DIR=/usr/local/bin
SERVICE_DIR=/etc/systemd/system
LOG_DIR=/var/log

# Go build flags
LDFLAGS=-ldflags="-w -s"
GOOS=linux
GOARCH=amd64

.PHONY: all build clean install uninstall test deps

all: build

# Build the binary
build:
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) go build $(LDFLAGS) -o $(BINARY_NAME) ./cmd/network-monitor

# Clean build artifacts
clean:
	rm -f $(BINARY_NAME)
	go clean

# Install dependencies
deps:
	go mod tidy
	go mod download

# Run tests
test:
	go test -v ./...

# Install the binary and service files
install: build
	@echo "Installing network monitor..."
	sudo install -m 755 $(BINARY_NAME) $(INSTALL_DIR)/
	sudo cp systemd/network-monitor-go.service $(SERVICE_DIR)/
	sudo cp systemd/network-wait-go.service $(SERVICE_DIR)/
	sudo mkdir -p $(LOG_DIR)
	sudo touch $(LOG_DIR)/network_startup_monitor.log
	sudo chmod 644 $(LOG_DIR)/network_startup_monitor.log
	sudo systemctl daemon-reload
	@echo "Installation complete. Use 'sudo make enable' to enable the service."

# Install non-blocking service
install-monitor: install
	sudo systemctl enable network-monitor-go.service
	@echo "Network monitor service enabled (non-blocking mode)"
	@echo "Start with: sudo systemctl start network-monitor-go"

# Install blocking service
install-wait: install
	sudo systemctl enable network-wait-go.service
	@echo "Network wait service enabled (blocking mode)"
	@echo "Service will start automatically on boot"

# Enable services
enable:
	sudo systemctl enable network-monitor-go.service
	@echo "Network monitor service enabled"

enable-wait:
	sudo systemctl enable network-wait-go.service
	@echo "Network wait service enabled"

# Disable services
disable:
	sudo systemctl disable network-monitor-go.service

disable-wait:
	sudo systemctl disable network-wait-go.service

# Uninstall everything
uninstall:
	@echo "Uninstalling network monitor..."
	sudo systemctl stop network-monitor-go.service 2>/dev/null || true
	sudo systemctl stop network-wait-go.service 2>/dev/null || true
	sudo systemctl disable network-monitor-go.service 2>/dev/null || true
	sudo systemctl disable network-wait-go.service 2>/dev/null || true
	sudo rm -f $(SERVICE_DIR)/network-monitor-go.service
	sudo rm -f $(SERVICE_DIR)/network-wait-go.service
	sudo rm -f $(INSTALL_DIR)/$(BINARY_NAME)
	sudo systemctl daemon-reload
	@echo "Uninstallation complete"

# Start/stop services
start:
	sudo systemctl start network-monitor-go.service

start-wait:
	sudo systemctl start network-wait-go.service

stop:
	sudo systemctl stop network-monitor-go.service

stop-wait:
	sudo systemctl stop network-wait-go.service

# View service status
status:
	sudo systemctl status network-monitor-go.service

status-wait:
	sudo systemctl status network-wait-go.service

# View logs
logs:
	sudo journalctl -u network-monitor-go.service -f

logs-wait:
	sudo journalctl -u network-wait-go.service -f

# View log file
tail:
	sudo tail -f $(LOG_DIR)/network_startup_monitor.log

# Build release binaries for multiple architectures
release:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build $(LDFLAGS) -o dist/$(BINARY_NAME)-linux-amd64 ./cmd/network-monitor
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build $(LDFLAGS) -o dist/$(BINARY_NAME)-linux-arm64 ./cmd/network-monitor
	CGO_ENABLED=0 GOOS=linux GOARCH=arm go build $(LDFLAGS) -o dist/$(BINARY_NAME)-linux-arm ./cmd/network-monitor

# Help
help:
	@echo "Available targets:"
	@echo "  build           - Build the binary"
	@echo "  clean           - Clean build artifacts"
	@echo "  deps            - Install dependencies"
	@echo "  test            - Run tests"
	@echo "  install         - Install binary and service files"
	@echo "  install-monitor - Install and enable non-blocking service"
	@echo "  install-wait    - Install and enable blocking service"
	@echo "  uninstall       - Remove everything"
	@echo "  start/stop      - Start/stop services"
	@echo "  status          - Show service status"
	@echo "  logs            - Follow service logs"
	@echo "  tail            - Follow log file"
	@echo "  release         - Build release binaries"
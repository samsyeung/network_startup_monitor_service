#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="network-wait"
SCRIPT_NAME="network_monitor.sh"

echo "Installing Network Wait Service (Blocking Mode)..."

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

echo "Creating log file and setting permissions..."
touch /var/log/network_monitor.log
chmod 644 /var/log/network_monitor.log

echo "Copying script to /usr/local/bin..."
cp "$SCRIPT_DIR/${SCRIPT_NAME}" "/usr/local/bin/"
chmod 755 "/usr/local/bin/${SCRIPT_NAME}"

echo "Copying service file to systemd..."
cp "$SCRIPT_DIR/${SERVICE_NAME}.service" "/etc/systemd/system/"

echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling ${SERVICE_NAME} service..."
systemctl enable "${SERVICE_NAME}.service"

echo ""
echo "Installation complete!"
echo ""
echo "WARNING: This service will BLOCK the boot process until network is fully ready."
echo "Services that depend on network-online.target will wait for this check to complete."
echo ""
echo "The service will automatically start on next boot and block until:"
echo "- All network interfaces have carrier signal"
echo "- All bond interfaces have completed LACP negotiation (if applicable)"
echo "- All network services are active"
echo "- Default gateway is reachable"
echo ""
echo "Maximum wait time: 15 minutes (900 seconds)"
echo ""
echo "To test the service now:"
echo "  sudo systemctl start ${SERVICE_NAME}"
echo ""
echo "To check service status:"
echo "  sudo systemctl status ${SERVICE_NAME}"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u ${SERVICE_NAME} -f"
echo "  sudo tail -f /var/log/network_monitor.log"
echo ""
echo "To disable the service:"
echo "  sudo systemctl disable ${SERVICE_NAME}"
echo ""
echo "For non-blocking monitoring, use install.sh instead."
#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="network-monitor"
SCRIPT_NAME="network_monitor.sh"

echo "Installing Network Monitor Service..."

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
echo "To start the service now:"
echo "  sudo systemctl start ${SERVICE_NAME}"
echo ""
echo "To check service status:"
echo "  sudo systemctl status ${SERVICE_NAME}"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u ${SERVICE_NAME} -f"
echo "  sudo tail -f /var/log/network_monitor.log"
echo ""
echo "To stop the service:"
echo "  sudo systemctl stop ${SERVICE_NAME}"
echo ""
echo "To disable the service:"
echo "  sudo systemctl disable ${SERVICE_NAME}"
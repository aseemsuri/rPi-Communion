#!/bin/bash
# Setup script for Communion systemd services

set -e

echo "=== Communion Service Setup ==="
echo ""

# Check if running as pi user
if [ "$USER" != "pi" ]; then
    echo "⚠️  This script should be run as the pi user (not root)"
    echo "Run: bash systemd/setup-services.sh"
    exit 1
fi

cd /home/pi/communion-project

echo "1. Creating sudoers rule for I2C bus reset..."
echo "   (This allows the Python script to reset I2C without password prompt)"
sudo tee /etc/sudoers.d/communion-i2c > /dev/null <<'EOF'
# Allow pi user to reset I2C bus without password
pi ALL=(ALL) NOPASSWD: /sbin/rmmod i2c_bcm2835
pi ALL=(ALL) NOPASSWD: /sbin/modprobe i2c_bcm2835
EOF

sudo chmod 440 /etc/sudoers.d/communion-i2c
echo "   ✓ Sudoers rule created"
echo ""

echo "2. Copying service files to /etc/systemd/system/..."
sudo cp systemd/communion-python.service /etc/systemd/system/
sudo cp systemd/communion-sc.service /etc/systemd/system/
echo "   ✓ Service files copied"
echo ""

echo "3. Reloading systemd daemon..."
sudo systemctl daemon-reload
echo "   ✓ Daemon reloaded"
echo ""

echo "4. Enabling services (auto-start on boot)..."
sudo systemctl enable communion-python
sudo systemctl enable communion-sc
echo "   ✓ Services enabled"
echo ""

echo "=== Setup Complete! ==="
echo ""
echo "Service management commands:"
echo "  Start:   sudo systemctl start communion-python communion-sc"
echo "  Stop:    sudo systemctl stop communion-python communion-sc"
echo "  Restart: sudo systemctl restart communion-python communion-sc"
echo "  Status:  sudo systemctl status communion-python communion-sc"
echo "  Logs:    journalctl -u communion-python -f"
echo ""
echo "After editing code:"
echo "  1. git pull"
echo "  2. sudo systemctl restart communion-python communion-sc"
echo ""
echo "Ready to start services? Run:"
echo "  sudo systemctl start communion-python communion-sc"

#!/bin/bash
# ============================================================================
# Communion SENSOR NODE setup  (MPR121 -> OSC only; NO audio / SuperCollider)
# ----------------------------------------------------------------------------
# Run on a fresh Raspberry Pi OS Lite after cloning the repo to
# ~/communion-project.  Installs only what a sensor node needs and enables
# ONLY the Python service to auto-start on boot (not SuperCollider).
#
#   git clone <repo> ~/communion-project
#   cd ~/communion-project
#   bash setup_sensor_node.sh
# ============================================================================
set -e

echo "=========================================="
echo " Communion SENSOR NODE setup (no audio)"
echo "=========================================="
echo ""

if [ ! -f /proc/device-tree/model ] || ! grep -q "Raspberry Pi" /proc/device-tree/model; then
    echo "Warning: this doesn't look like a Raspberry Pi."
    read -p "Continue anyway? (y/N) " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

echo "Step 1/5: Installing system dependencies (no supercollider/jackd2)..."
sudo apt update
sudo apt install -y git python3-pip python3-venv i2c-tools

echo ""
echo "Step 2/5: Enabling I2C..."
sudo raspi-config nonint do_i2c 0

echo ""
echo "Step 3/5: Python virtual environment + dependencies..."
if [ ! -d ~/mpr121-env ]; then
    python3 -m venv ~/mpr121-env
fi
source ~/mpr121-env/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

echo ""
echo "Step 4/5: Sudoers rule so the script can reset the I2C bus without a password..."
sudo tee /etc/sudoers.d/communion-i2c > /dev/null <<'EOF'
pi ALL=(ALL) NOPASSWD: /sbin/rmmod i2c_bcm2835
pi ALL=(ALL) NOPASSWD: /sbin/modprobe i2c_bcm2835
EOF
sudo chmod 440 /etc/sudoers.d/communion-i2c

echo ""
echo "Step 5/5: Installing + enabling the Python service ONLY (no communion-sc)..."
sudo cp systemd/communion-python.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable communion-python
# Ensure the audio service is not left enabled on a sensor node (safe if absent)
sudo systemctl disable communion-sc 2>/dev/null || true

echo ""
echo "=========================================="
echo " Sensor node setup complete!"
echo "=========================================="
echo ""
echo "Before first run, set this node's identity in python/sensor_config.json:"
echo "    \"node_id\": \"csn1\"     (csn2, csn3, ... per box)"
echo "Make sure the OSC target is correct too:"
echo "    \"osc\": { \"send_to_mac\": true, \"mac_ip\": \"192.168.1.177\", ... }"
echo ""
echo "Then reboot — communion-python starts on boot and sends /<node_id>/touchN:"
echo "    sudo reboot"
echo ""
echo "Watch it live:   journalctl -u communion-python -f"
echo "Restart it:      sudo systemctl restart communion-python"

#!/bin/bash

# Automated setup script for rPi-Communion project on a new Raspberry Pi
# Run this on a fresh Pi to install all dependencies and set up the project

set -e  # Exit on any error

echo "=========================================="
echo "rPi-Communion Project Setup"
echo "=========================================="
echo ""

# Check if running on Raspberry Pi
if [ ! -f /proc/device-tree/model ] || ! grep -q "Raspberry Pi" /proc/device-tree/model; then
    echo "Warning: This doesn't appear to be a Raspberry Pi"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "Step 1: Updating system packages..."
sudo apt update

echo ""
echo "Step 2: Installing system dependencies..."
sudo apt install -y \
    supercollider \
    jackd2 \
    git \
    python3-pip \
    python3-venv \
    i2c-tools \
    libasound2-dev

echo ""
echo "Step 3: Enabling I2C interface..."
sudo raspi-config nonint do_i2c 0

echo ""
echo "Step 4: Creating Python virtual environment..."
if [ -d ~/mpr121-env ]; then
    echo "Virtual environment already exists, skipping..."
else
    python3 -m venv ~/mpr121-env
fi

echo ""
echo "Step 5: Installing Python dependencies..."
source ~/mpr121-env/bin/activate
pip3 install --upgrade pip
pip3 install -r requirements.txt
deactivate

echo ""
echo "Step 6: Setting up JACK configuration..."
if [ ! -f ~/.jackdrc ]; then
    cp .jackdrc ~/
    echo "JACK config copied to home directory"
fi

echo ""
echo "Step 7: Fixing USB audio card to always be hw:3..."
sudo tee /etc/modprobe.d/alsa-base.conf > /dev/null <<EOF
# Force specific card order
options snd_usb_audio index=3
options snd_rpi_hifiberry_dac index=1
options vc4 index=2
options snd_dummy index=0
EOF
echo "Audio card order fixed (USB will be hw:3)"

echo ""
echo "Step 8: Setting permissions for audio..."
sudo usermod -a -G audio $USER

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Reboot the Pi: sudo reboot"
echo "2. After reboot, test the project:"
echo "   cd ~/communion-project"
echo "   ./run_supercollider.sh  # In one terminal"
echo "   ./run_python.sh         # In another terminal"
echo ""
echo "3. Touch the sensors to verify everything works!"
echo ""

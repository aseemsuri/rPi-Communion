#!/bin/bash

# Fix USB audio card number to always be card 3
# Based on current setup:
# card 0: Dummy
# card 1: HiFiBerry DAC
# card 2: vc4-hdmi
# card 3: AB13X USB Audio (target)

echo "Creating ALSA configuration to fix audio card order..."

sudo tee /etc/modprobe.d/alsa-base.conf > /dev/null <<EOF
# Force specific card order
options snd_usb_audio index=3
options snd_rpi_hifiberry_dac index=1
options vc4 index=2
options snd_dummy index=0
EOF

echo "Configuration created. You need to reboot for this to take effect."
echo "Run: sudo reboot"
echo ""
echo "After reboot, USB Audio should always be at card 3"
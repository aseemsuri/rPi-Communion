#!/bin/bash

# Trap Ctrl+C and cleanup
cleanup() {
    echo "Shutting down SuperCollider and JACK..."
    killall sclang
    sleep 1
    killall jackd
    exit 0
}

trap cleanup SIGINT SIGTERM

# Run SuperCollider with xvfb (virtual framebuffer for headless operation)
cd /home/pi/communion-project
xvfb-run -a sclang supercollider/communion_sc_cl3.scd

# If sclang exits normally, still cleanup
cleanup

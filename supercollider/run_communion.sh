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

# Run SuperCollider
QT_QPA_PLATFORM=offscreen QT_XCB_GL_INTEGRATION=none LIBGL_ALWAYS_SOFTWARE=1 sclang /home/pi/sc/communion_sc_cl3.scd

# If sclang exits normally, still cleanup
cleanup
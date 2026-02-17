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

# Run SuperCollider in headless mode with Qt offscreen rendering
cd /home/pi/communion-project
QT_QPA_PLATFORM=offscreen QT_XCB_GL_INTEGRATION=none LIBGL_ALWAYS_SOFTWARE=1 sclang supercollider/communion_sc_cl3.scd

# If sclang exits normally, still cleanup
cleanup

#!/bin/bash

# Trap Ctrl+C for cleanup
cleanup() {
    echo "Shutting down Python script..."
    exit 0
}

trap cleanup SIGINT SIGTERM

# Activate virtual environment and run Python
cd /home/pi/communion-project
source /home/pi/mpr121-env/bin/activate
python3 python/communion_python_cl1.py

# Cleanup on normal exit
cleanup
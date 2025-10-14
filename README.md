# Communion Project

Interactive music system using Python and SuperCollider on Raspberry Pi Zero 2W.

## Hardware
- Raspberry Pi Zero 2W
- MPR121 capacitive touch sensor
- Audio interface

## Setup

### Python Environment
```bash
# Activate existing virtual environment
source /home/pi/mpr121-env/bin/activate

# Or create a new one if needed
python3 -m venv venv
source venv/bin/activate
pip install -r python/requirements.txt
```

### SuperCollider
Scripts are in the \`supercollider/\` directory. Audio samples in \`supercollider/samples/\`.

# run headless:
QT_QPA_PLATFORM=offscreen QT_XCB_GL_INTEGRATION=none LIBGL_ALWAYS_SOFTWARE=1 sclang /home/pi/sc/communion_sc_cl3.scd

## Components

### Run Jack first
# identify audio device
aplay -l
# run jack on correct hw: number
jackd -d alsa -d hw:3,0 -r 44100 -p 256 -n 2

### Python Scripts
- \`communion_python_cl1.py\` - Main Python controller
- \`mpr121_osc_sender.py\` - MPR121 sensor OSC sender

# commands:
python /home/pi/communion-project/python/communion_python_cl1.py


### SuperCollider Scripts
- \`communion_sc_cl*.scd\` - Main SuperCollider patches
- \`osc_*.scd\` - OSC test scripts



## TO DO
- make 1 work
- make 3 work
- make 12 work
- make jack automatic
- make scripts automatic
[Add your run instructions here]
EOF"
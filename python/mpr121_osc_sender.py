import time
import board
import busio
import adafruit_mpr121
from pythonosc.udp_client import SimpleUDPClient

# RAW_MIN = 100    # Expected minimum raw value when touched
# RAW_MAX = 340    # Expected maximum raw value when idle

RAW_MIN = [45] * 12  # When touched
RAW_MAX = [111, 111,111, 111, 111, 111, 111,85, 85, 85, 85, 55]  # Use your actual idle values per pad

# RAW_MIN = 40
# RAW_MAX = 120

SMOOTHING_ALPHA = 0.7
CHANGE_SMOOTH_ALPHA = 0.2
previous_values = [0.0] * 12
smoothed_changes = [0.0] * 12
MAX_DELTA = 10

# SETUP I2C + MPR121
i2c = busio.I2C(board.SCL, board.SDA)
mpr121 = adafruit_mpr121.MPR121(i2c)

def map_touch_value(raw_value, raw_min, raw_max, out_min=0, out_max=100, reverse=True):
    """
    Maps raw_value from raw_min–raw_max to out_min–out_max.
    If reverse=True, inverts the mapping so low raw = high output.
    Clamps result between out_min and out_max.
    """
    # Prevent divide by zero
    if raw_max == raw_min:
        return out_min

    # Normalize between 0 and 1
    norm = (raw_value - raw_min) / (raw_max - raw_min)

    if reverse:
        norm = 1.0 - norm

    # Clamp between 0 and 1
    norm = max(0.0, min(1.0, norm))

    # Scale to output range
    scaled = norm * (out_max - out_min) + out_min

    return scaled


# Disable baseline tracking for stable pressure sensing
#mpr121._write_register_byte(0x2B, 0x00)
#mpr121._write_register_byte(0x5B, 0x00)
#mpr121._write_register_byte(0x5C, 0x00)
#mpr121._write_register_byte(0x5D, 0x00)
#mpr121._write_register_byte(0x5E, 0x00)

# Reduce charge/discharge current
#mpr121._write_register_byte(0x5F, 0x10)  # CDC lower

# Increase charge/discharge time
#mpr121._write_register_byte(0x6C, 0x04)  # CDT slower

# Set thresholds higher for stability
#for i in range(12):
#    mpr121._write_register_byte(0x41 + 2*i, 40)  # Touch
#    mpr121._write_register_byte(0x42 + 2*i, 20)  # Release
for i in range(12):
    mpr121[i].threshold = 100  #higher is less sensitive
    mpr121[i].release_threshold = 40

smoothed_values = [0.0] * 12


# SETUP OSC CLIENT
#osc_ip = "192.168.1.177"
osc_ip = "127.0.0.1"
osc_port = 57120
client = SimpleUDPClient(osc_ip, osc_port)

#print(f"Sending OSC to {osc_ip}:{osc_port}")

try:
    while True:
        for i in range(11,12):
            value = mpr121.filtered_data(i)
            print(f"Pad {i}: {mpr121.filtered_data(i)}")
#            if (i==11): value = value - 27
            raw_mapped = map_touch_value(value, RAW_MIN[i], RAW_MAX[i])
            smoothed_values[i] = SMOOTHING_ALPHA * raw_mapped + (1-SMOOTHING_ALPHA) * smoothed_values[i]
	    # Clamp delta change
            if abs(raw_mapped - smoothed_values[i]) > MAX_DELTA:
            	raw_mapped = smoothed_values[i]  # Ignore spike
           
            # Calculate change   
#            change = smoothed_values[i] - previous_values[i]
            previous_values[i] = smoothed_values[i]

            # Optional smoothing for change
#            smoothed_changes[i] = CHANGE_SMOOTH_ALPHA * change + (1 - CHANGE_SMOOTH_ALPHA) * smoothed_changes[i]
#            client.send_message("/touch1", smoothed_changes[i]*10.)
            client.send_message("/touch"+str(i), smoothed_values[i])
#            print(f"Sending OSC: /touch{i} {smoothed_values[i]} ({type(smoothed_values[i])})")
#            print(f"Channel {i}: raw={value}, normalized={smoothed_changes[i]}")
        time.sleep(0.05)

except KeyboardInterrupt:
    print("\nExiting.")

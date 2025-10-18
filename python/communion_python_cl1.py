import time
import board
import busio
import adafruit_mpr121
from pythonosc.udp_client import SimpleUDPClient

# ---- CALIBRATION ----
# Adjust these per sensor based on idle vs touched readings
RAW_MIN = [45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45]      # Expected minimum raw value when touched
RAW_MAX = [85, 85, 85, 85, 85, 85, 85, 85, 85, 66, 83, 98]  # Idle values

# ---- SMOOTHING & FILTERING ----
SMOOTHING_ALPHA = 0.4
MAX_DELTA = 10
POLL_INTERVAL = 0.01  # 10ms polling

# ---- SETUP I2C + MPR121 ----
i2c = busio.I2C(board.SCL, board.SDA)
mpr121 = adafruit_mpr121.MPR121(i2c)

# Configure thresholds for stability
for i in range(12):
    mpr121[i].threshold = 100        # Higher = less sensitive
    mpr121[i].release_threshold = 40

smoothed_values = [0.0] * 12

# ---- SETUP OSC CLIENT ----
osc_ip = "127.0.0.1"
osc_port = 57120
client = SimpleUDPClient(osc_ip, osc_port)


def map_touch_value(raw_value, raw_min, raw_max, out_min=0, out_max=100, reverse=True):
    """
    Maps raw_value from [raw_min, raw_max] to [out_min, out_max].
    If reverse=True, inverts so lower raw values = higher output (touch = high).
    Clamps result between out_min and out_max.
    """
    if raw_max == raw_min:
        return out_min
    
    norm = (raw_value - raw_min) / (raw_max - raw_min)
    if reverse:
        norm = 1.0 - norm
    norm = max(0.0, min(1.0, norm))
    scaled = norm * (out_max - out_min) + out_min
    return scaled


def apply_spike_filter(new_value, prev_value, max_delta):
    """Reject spikes larger than max_delta."""
    if abs(new_value - prev_value) > max_delta:
        return prev_value
    return new_value


def calibrate_sensors(duration=3.0, buffer=3):
    """
    Calibrate sensors by finding minimum values over duration seconds.
    Returns calibrated RAW_MAX array.
    """
    print(f"\n=== CALIBRATION MODE ===")
    print(f"Sampling sensors for {duration} seconds...")
    print("Please keep hands OFF all sensors!\n")

    # Track minimum values for each sensor
    min_values = [float('inf')] * 12

    start_time = time.time()
    sample_count = 0

    while (time.time() - start_time) < duration:
        for i in range(12):
            raw_value = mpr121.filtered_data(i)
            if raw_value < min_values[i]:
                min_values[i] = raw_value

        sample_count += 1
        time.sleep(0.01)  # 10ms sampling

    # Calculate calibrated RAW_MAX values (min - buffer)
    calibrated_max = [max(int(min_val - buffer), 0) for min_val in min_values]

    print(f"Calibration complete! ({sample_count} samples)\n")
    print("Detected minimum values per sensor:")
    for i in range(12):
        print(f"  touch{i}: min={int(min_values[i])}, calibrated_max={calibrated_max[i]}")

    return calibrated_max


try:
    print(f"OSC Client ready: {osc_ip}:{osc_port}")

    # Run calibration
    RAW_MAX = calibrate_sensors(duration=3.0, buffer=3)

    print("\nStarting main loop... Press Ctrl+C to exit.\n")
    
    while True:
        # Poll all 12 channels
        for i in range(9,12):
            raw_value = mpr121.filtered_data(i)
#            print(f"Pad{i}: {raw_value}")
            # Map raw sensor value to 0-100 range
            raw_mapped = map_touch_value(raw_value, RAW_MIN[i], RAW_MAX[i])
            
            # Spike filter
#            raw_mapped = apply_spike_filter(raw_mapped, smoothed_values[i], MAX_DELTA)
            
            # Exponential moving average smoothing
            smoothed_values[i] = (SMOOTHING_ALPHA * raw_mapped + 
                                 (1 - SMOOTHING_ALPHA) * smoothed_values[i])
            
            # Send OSC message
            osc_path = f"/touch{i}"
#            print(osc_path)
            client.send_message(osc_path, smoothed_values[i])
            
            # Debug output (optional: comment out for cleaner output)
#            print(f"Pad {i}: raw={raw_value:3d} → mapped={raw_mapped:6.2f} → smoothed={smoothed_values[i]:6.2f} → oscPath={osc_path}")
        
        time.sleep(POLL_INTERVAL)

except KeyboardInterrupt:
    print("\nExiting.")
except Exception as e:
    print(f"Error: {e}")
    raise

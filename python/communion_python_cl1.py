import time
import board
import busio
import adafruit_mpr121
from pythonosc.udp_client import SimpleUDPClient
import subprocess
import sys

# ---- CALIBRATION ----
# Adjust these per sensor based on idle vs touched readings
RAW_MIN = [45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45]      # Expected minimum raw value when touched
RAW_MAX = [85, 85, 85, 85, 85, 85, 85, 85, 85, 66, 83, 98]  # Idle values

# ---- SMOOTHING & FILTERING ----
SMOOTHING_ALPHA = 0.4
MAX_DELTA = 10
POLL_INTERVAL = 0.01  # 10ms polling

# ---- RETRY SETTINGS ----
MAX_RETRIES = 5
RETRY_DELAY = 2  # seconds between retries


def reset_i2c_bus():
    """Reset the I2C bus by reloading the kernel module."""
    try:
        print("Resetting I2C bus...")
        subprocess.run(['sudo', 'rmmod', 'i2c_bcm2835'], check=False)
        time.sleep(0.5)
        subprocess.run(['sudo', 'modprobe', 'i2c_bcm2835'], check=True)
        time.sleep(1)
        print("I2C bus reset complete")
        return True
    except Exception as e:
        print(f"Could not reset I2C bus: {e}")
        return False


def initialize_mpr121_with_retry():
    """Initialize MPR121 with automatic retry and I2C reset on failure."""
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            print(f"Initializing MPR121 (attempt {attempt}/{MAX_RETRIES})...")
            i2c = busio.I2C(board.SCL, board.SDA)
            mpr121 = adafruit_mpr121.MPR121(i2c)

            # Configure thresholds for stability
            for i in range(12):
                mpr121[i].threshold = 100
                mpr121[i].release_threshold = 40

            print("✓ MPR121 initialized successfully!")
            return mpr121

        except Exception as e:
            print(f"✗ Initialization failed: {e}")

            if attempt < MAX_RETRIES:
                if attempt > 1:  # Reset I2C after first failure
                    reset_i2c_bus()
                print(f"Retrying in {RETRY_DELAY} seconds...\n")
                time.sleep(RETRY_DELAY)
            else:
                print("\n❌ Failed to initialize MPR121 after all retries")
                print("Please check:")
                print("  1. Power connections (3.3V and GND)")
                print("  2. SDA/SCL wiring (GPIO 2/3)")
                print("  3. Run: i2cdetect -y 1")
                sys.exit(1)


# ---- SETUP I2C + MPR121 ----
mpr121 = initialize_mpr121_with_retry()

smoothed_values = [0.0] * 12

# ---- SETUP OSC CLIENT ----
osc_ip = "127.0.0.1"
#osc_ip = "192.168.1.177"
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


def read_sensor_with_retry(mpr121, sensor_index, max_attempts=3):
    """Read sensor with retry on I/O errors."""
    for attempt in range(max_attempts):
        try:
            return mpr121.filtered_data(sensor_index)
        except OSError as e:
            if e.errno == 5 and attempt < max_attempts - 1:  # I/O error
                print(f"⚠ I/O error reading sensor {sensor_index}, retrying...")
                time.sleep(0.1)
            else:
                raise
    return None


def calibrate_sensors(duration=3.0, buffer=3):
    """
    Calibrate sensors by finding minimum values over duration seconds.
    Returns calibrated RAW_MAX array.
    """
    print(f"\n=== CALIBRATION MODE ===")
    print(f"Sampling sensors for {duration} seconds...")
    print("Please keep hands OFF all sensors!\n")
    buffer = 1
    # Track minimum values for each sensor
    min_values = [float('inf')] * 12

    start_time = time.time()
    sample_count = 0

    while (time.time() - start_time) < duration:
        for i in range(12):
            try:
                raw_value = read_sensor_with_retry(mpr121, i)
                if raw_value is not None and raw_value < min_values[i]:
                    min_values[i] = raw_value
            except Exception as e:
                print(f"⚠ Error reading sensor {i} during calibration: {e}")
                continue

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
    
    consecutive_errors = 0
    MAX_CONSECUTIVE_ERRORS = 10

    while True:
        try:
            # Poll all 12 channels
            for i in range(9,12):
                try:
                    raw_value = read_sensor_with_retry(mpr121, i)
                    if raw_value is None:
                        continue

                    # Map raw sensor value to 0-100 range
                    raw_mapped = map_touch_value(raw_value, RAW_MIN[i], RAW_MAX[i])

                    # Spike filter
                    # raw_mapped = apply_spike_filter(raw_mapped, smoothed_values[i], MAX_DELTA)

                    # Exponential moving average smoothing
                    smoothed_values[i] = (SMOOTHING_ALPHA * raw_mapped +
                                         (1 - SMOOTHING_ALPHA) * smoothed_values[i])

                    # Send OSC message
                    osc_path = f"/touch{i}"
                    client.send_message(osc_path, smoothed_values[i])

                    # Reset error counter on successful read
                    consecutive_errors = 0

                except OSError as e:
                    consecutive_errors += 1
                    print(f"⚠ I/O error on sensor {i} (error #{consecutive_errors})")

                    if consecutive_errors >= MAX_CONSECUTIVE_ERRORS:
                        print(f"\n❌ Too many consecutive errors ({consecutive_errors})")
                        print("Attempting to reinitialize MPR121...")
                        mpr121 = initialize_mpr121_with_retry()
                        consecutive_errors = 0
                        break  # Break out of sensor loop to restart

                    time.sleep(0.1)  # Brief pause before continuing
                    continue

            time.sleep(POLL_INTERVAL)

        except Exception as e:
            print(f"⚠ Unexpected error in main loop: {e}")
            consecutive_errors += 1

            if consecutive_errors >= MAX_CONSECUTIVE_ERRORS:
                print("Reinitializing MPR121 due to persistent errors...")
                mpr121 = initialize_mpr121_with_retry()
                consecutive_errors = 0

            time.sleep(1)

except KeyboardInterrupt:
    print("\n\n👋 Shutting down gracefully...")
except Exception as e:
    print(f"\n❌ Fatal error: {e}")
    print("Script terminated.")
    raise

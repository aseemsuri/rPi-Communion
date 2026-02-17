import time
import board
import busio
import adafruit_mpr121
from pythonosc.udp_client import SimpleUDPClient
from pythonosc.dispatcher import Dispatcher
from pythonosc.osc_server import ThreadingOSCUDPServer
import subprocess
import sys
import json
import os
import threading
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# ---- CONFIG FILE ----
CONFIG_FILE = "/home/pi/communion-project/python/sensor_config.json"
config_lock = threading.Lock()

# Will be loaded from config or auto-calibrated
RAW_MIN = [45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45]  # Default touched values
RAW_MAX = [85, 85, 85, 85, 85, 85, 85, 85, 85, 66, 83, 98]   # Default idle values

# ---- SMOOTHING & FILTERING ----
SMOOTHING_ALPHA = 0.4
MAX_DELTA = 10
POLL_INTERVAL = 0.01  # 10ms polling

# ---- RETRY SETTINGS ----
MAX_RETRIES = 5
RETRY_DELAY = 2  # seconds between retries


def load_config():
    """Load sensor configuration from JSON file."""
    global RAW_MIN, RAW_MAX

    if not os.path.exists(CONFIG_FILE):
        print(f"ℹ Config file not found at {CONFIG_FILE}")
        return False

    # Check if file has content (avoid reading while VSCode is writing)
    if os.path.getsize(CONFIG_FILE) == 0:
        return False

    try:
        with config_lock:
            with open(CONFIG_FILE, 'r') as f:
                config = json.load(f)

            # Load thresholds for each sensor
            for i in range(12):
                sensor_key = f"sensor_{i}"
                if sensor_key in config:
                    # New naming: trigger_threshold (high raw) and max_pressure (low raw)
                    # Fall back to old naming for backward compatibility
                    RAW_MIN[i] = config[sensor_key].get("max_pressure",
                                 config[sensor_key].get("min_value", RAW_MIN[i]))
                    RAW_MAX[i] = config[sensor_key].get("trigger_threshold",
                                 config[sensor_key].get("max_value", RAW_MAX[i]))

            print(f"✓ Config loaded from {CONFIG_FILE}")
            return True

    except Exception as e:
        print(f"⚠ Error loading config: {e}")
        return False


def save_config():
    """Save current sensor configuration to JSON file."""
    global RAW_MIN, RAW_MAX

    config = {}
    for i in range(12):
        config[f"sensor_{i}"] = {
            "max_pressure": int(RAW_MIN[i]),        # Low raw value (strong touch)
            "trigger_threshold": int(RAW_MAX[i])    # High raw value (light touch/idle)
        }

    try:
        with config_lock:
            with open(CONFIG_FILE, 'w') as f:
                json.dump(config, f, indent=2)

        print(f"✓ Config saved to {CONFIG_FILE}")
        return True

    except Exception as e:
        print(f"⚠ Error saving config: {e}")
        return False


class ConfigFileHandler(FileSystemEventHandler):
    """Watches config file for changes and reloads."""
    def __init__(self):
        self.last_modified = 0

    def on_modified(self, event):
        if event.src_path.endswith('sensor_config.json'):
            # Debounce: avoid multiple triggers
            current_time = time.time()
            if current_time - self.last_modified < 1.0:
                return

            self.last_modified = current_time
            print("\n🔄 Config file changed, reloading...")

            # Wait for file write to complete, then retry if needed
            time.sleep(0.2)  # Longer initial delay for VSCode writes
            success = False
            for attempt in range(5):  # More retries
                if load_config():
                    success = True
                    break
                if attempt < 4:
                    time.sleep(0.15)  # Slightly longer between retries

            if not success:
                print("⚠ Config reload timed out (file may still be writing)")


def start_config_watcher():
    """Start watching config file for changes."""
    config_dir = os.path.dirname(CONFIG_FILE)
    event_handler = ConfigFileHandler()
    observer = Observer()
    observer.schedule(event_handler, config_dir, recursive=False)
    observer.start()
    print(f"👁 Watching {CONFIG_FILE} for changes...")
    return observer


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
    print("Detected calibrated values per sensor:")
    for i in range(12):
        print(f"  sensor_{i}: max_pressure={RAW_MIN[i]}, trigger_threshold={calibrated_max[i]}")

    # Update global RAW_MAX with calibrated values
    global RAW_MAX
    RAW_MAX = calibrated_max

    # Save to config file
    print("\n💾 Saving calibration to config file...")
    save_config()

    return calibrated_max


# ---- OSC CONTROL HANDLERS ----
def handle_sensor_min(address, *args):
    """Handle /sensorX/pressure messages to set max pressure threshold (low raw value)."""
    try:
        # Extract sensor number from address like "/sensor9/pressure"
        sensor_num = int(address.split('/')[1].replace('sensor', ''))
        if 0 <= sensor_num <= 11 and len(args) > 0:
            new_pressure = int(args[0])
            RAW_MIN[sensor_num] = new_pressure
            print(f"📥 OSC: sensor_{sensor_num} max_pressure = {new_pressure}")
            save_config()  # Auto-save on OSC change
    except Exception as e:
        print(f"⚠ Error handling {address}: {e}")


def handle_sensor_max(address, *args):
    """Handle /sensorX/trigger messages to set trigger threshold (high raw value)."""
    try:
        # Extract sensor number from address like "/sensor9/trigger"
        sensor_num = int(address.split('/')[1].replace('sensor', ''))
        if 0 <= sensor_num <= 11 and len(args) > 0:
            new_trigger = int(args[0])
            RAW_MAX[sensor_num] = new_trigger
            print(f"📥 OSC: sensor_{sensor_num} trigger_threshold = {new_trigger}")
            save_config()  # Auto-save on OSC change
    except Exception as e:
        print(f"⚠ Error handling {address}: {e}")


def handle_recalibrate(address, *args):
    """Handle /recalibrate message to run calibration."""
    print("\n📥 OSC: Recalibration requested...")
    global RAW_MAX
    RAW_MAX = calibrate_sensors(duration=3.0, buffer=3)


def start_osc_server():
    """Start OSC server for receiving control messages."""
    dispatcher = Dispatcher()

    # Map OSC addresses to handlers
    for i in range(12):
        dispatcher.map(f"/sensor{i}/pressure", handle_sensor_min)
        dispatcher.map(f"/sensor{i}/trigger", handle_sensor_max)

    dispatcher.map("/recalibrate", handle_recalibrate)

    # Start server on port 57121 (different from SuperCollider's 57120)
    server = ThreadingOSCUDPServer(("0.0.0.0", 57121), dispatcher)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    print(f"🎛 OSC Control Server listening on port 57121")
    print("   Commands:")
    print("     /sensorX/pressure <value>  - Set max pressure (low raw, e.g., /sensor9/pressure 45)")
    print("     /sensorX/trigger <value>   - Set trigger threshold (high raw, e.g., /sensor9/trigger 90)")
    print("     /recalibrate               - Run auto-calibration")
    return server


try:
    print(f"OSC Client ready: {osc_ip}:{osc_port}")

    # Load config or run calibration
    if not load_config():
        print("🔧 No config found, running auto-calibration...")
        RAW_MAX = calibrate_sensors(duration=3.0, buffer=3)
    else:
        print("✓ Using values from config file")

    # Start config file watcher for hot-reload
    config_observer = start_config_watcher()

    # Start OSC control server
    osc_server = start_osc_server()

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

                    # Debug output for sensor 10 - show ALL values including idle
                    if i == 10:
                        print(f"DEBUG sensor_10: raw={raw_value}, trigger={RAW_MAX[i]}, pressure={RAW_MIN[i]}, out={raw_mapped:.1f}")

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
    if 'config_observer' in locals():
        config_observer.stop()
        config_observer.join()
    if 'osc_server' in locals():
        osc_server.shutdown()
except Exception as e:
    print(f"\n❌ Fatal error: {e}")
    print("Script terminated.")
    if 'config_observer' in locals():
        config_observer.stop()
    if 'osc_server' in locals():
        osc_server.shutdown()
    raise

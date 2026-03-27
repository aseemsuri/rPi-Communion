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
RAW_MIN = [45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45]   # max_pressure: low raw value (hard touch)
RAW_MAX = [85, 85, 85, 85, 85, 85, 85, 85, 85, 66, 83, 98]   # trigger_threshold: = RAW_IDLE - CALIBRATION_BUFFER
RAW_IDLE = [None] * 12                                         # raw_idle: actual measured minimum when untouched

# Hardware thresholds (MPR121 chip settings, 0-255, lower=more sensitive)
# Using Bare Conductive defaults optimized for plants: 40/20 (more sensitive than Adafruit default 12/6)
HW_TOUCH_THRESHOLD = [40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40]  # Default: 40
HW_RELEASE_THRESHOLD = [20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20]  # Default: 20

# ---- SMOOTHING & FILTERING ----
SMOOTHING_ALPHA = 0.4
MAX_DELTA = 10
POLL_INTERVAL = 0.02  # 20ms polling

# ---- RETRY SETTINGS ----
MAX_RETRIES = 5
RETRY_DELAY = 2  # seconds between retries

# ---- CALIBRATION ----
CALIBRATION_INTERVAL_HOURS = 0  # 0 = startup only, N = recalibrate every N hours
CALIBRATION_BUFFER = 2          # Subtract this from lowest idle value to set trigger_threshold
MASTER_VOLUME = 0.8              # Default master volume (0.0-1.0)
_last_calibration_time = None
is_calibrating = False           # Pauses main loop during calibration to avoid I2C conflicts


def load_config():
    """Load sensor configuration from JSON file."""
    global RAW_MIN, RAW_MAX, RAW_IDLE, HW_TOUCH_THRESHOLD, HW_RELEASE_THRESHOLD, CALIBRATION_INTERVAL_HOURS, CALIBRATION_BUFFER, MASTER_VOLUME

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

            # Top-level settings (load buffer first — needed for recomputing thresholds below)
            CALIBRATION_INTERVAL_HOURS = config.get("calibration_interval_hours", CALIBRATION_INTERVAL_HOURS)
            CALIBRATION_BUFFER = config.get("calibration_buffer", CALIBRATION_BUFFER)
            MASTER_VOLUME = config.get("master_volume", MASTER_VOLUME)

            # Load thresholds for each sensor
            for i in range(12):
                sensor_key = f"sensor_{i}"
                if sensor_key in config:
                    RAW_MIN[i] = config[sensor_key].get("max_pressure",
                                 config[sensor_key].get("min_value", RAW_MIN[i]))

                    # Hardware thresholds (MPR121 chip sensitivity, 0-255)
                    HW_TOUCH_THRESHOLD[i] = config[sensor_key].get("touch_threshold", HW_TOUCH_THRESHOLD[i])
                    HW_RELEASE_THRESHOLD[i] = config[sensor_key].get("release_threshold", HW_RELEASE_THRESHOLD[i])

                    # Load raw_idle if present, then recompute trigger_threshold from it
                    # This means changing calibration_buffer in the config instantly updates thresholds
                    idle = config[sensor_key].get("raw_idle", None)
                    if idle is not None:
                        RAW_IDLE[i] = idle
                        RAW_MAX[i] = max(int(idle - CALIBRATION_BUFFER), 0)
                    else:
                        # No raw_idle yet (pre-first-calibration) — use stored trigger_threshold directly
                        RAW_MAX[i] = config[sensor_key].get("trigger_threshold",
                                     config[sensor_key].get("max_value", RAW_MAX[i]))

            print(f"✓ Config loaded from {CONFIG_FILE} (buffer={CALIBRATION_BUFFER})")
            return True

    except Exception as e:
        print(f"⚠ Error loading config: {e}")
        return False


def save_config():
    """Save current sensor configuration to JSON file."""
    global RAW_MIN, RAW_MAX, HW_TOUCH_THRESHOLD, HW_RELEASE_THRESHOLD

    config = {
        "calibration_interval_hours": CALIBRATION_INTERVAL_HOURS,
        "calibration_buffer": CALIBRATION_BUFFER
    }
    for i in range(12):
        config[f"sensor_{i}"] = {
            "max_pressure": int(RAW_MIN[i]),            # Low raw value (strong touch)
            "trigger_threshold": int(RAW_MAX[i]),       # High raw value (light touch/idle)
            "touch_threshold": int(HW_TOUCH_THRESHOLD[i]),      # Hardware sensitivity (0-255, lower=more sensitive)
            "release_threshold": int(HW_RELEASE_THRESHOLD[i])   # Hardware release threshold (0-255)
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
                    apply_hardware_thresholds()  # Apply hardware thresholds after reload

                    # Check for recalibrate_now flag — set to true in config to trigger on-demand
                    try:
                        with open(CONFIG_FILE, 'r') as f:
                            cfg = json.load(f)
                        if cfg.get("recalibrate_now", False):
                            print("🔧 recalibrate_now flag detected — starting calibration...")
                            # Clear the flag first so it doesn't re-trigger
                            cfg["recalibrate_now"] = False
                            with open(CONFIG_FILE, 'w') as f:
                                json.dump(cfg, f, indent=2)
                            threading.Thread(target=calibrate_sensors, daemon=True).start()
                    except Exception as e:
                        print(f"⚠ Error checking recalibrate_now: {e}")

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
    """Soft reset - wait for bus to recover naturally."""
    time.sleep(1)
    return True


def configure_mpr121_filters(mpr121):
    """
    Configure MPR121 filter settings optimized for plant sensing.
    Based on Bare Conductive Arduino library defaults that worked with Max/MSP.

    Registers:
    - CONFIG1/AFE1 (0x5C): FFI (First Filter Iterations)
    - CONFIG2/AFE2 (0x5D): CDT (Charge Discharge Time) and SFI (Second Filter Iterations)

    Settings:
    - FFI_10 (0x01): 10 samples for first-level filtering
    - SFI_10 (0x02): 10 samples for second-level filtering
    - CDT_4US (0x04): 4 microsecond charge time - "reasonable for larger capacitances" (succulents!)
    """
    try:
        # MPR121 register addresses
        MPR121_CONFIG1 = 0x5C  # Also called AFE1
        MPR121_CONFIG2 = 0x5D  # Also called AFE2

        # Read current register values
        current_config1 = mpr121._i2c_device.read(MPR121_CONFIG1, 1)[0]
        current_config2 = mpr121._i2c_device.read(MPR121_CONFIG2, 1)[0]

        # Configure CONFIG1: Set FFI_10 (bits 6-7)
        # FFI_10 = 0x01, shifted left 6 bits = 0x40
        new_config1 = (current_config1 & 0x3F) | (0x01 << 6)

        # Configure CONFIG2: Set CDT_4US (bits 5-7) and SFI_10 (bits 3-4)
        # CDT_4US = 0x04, shifted left 5 bits = 0x80
        # SFI_10 = 0x02, shifted left 3 bits = 0x10
        temp_config2 = (current_config2 & 0x1F) | (0x04 << 5)  # Set CDT
        new_config2 = (temp_config2 & 0xE7) | (0x02 << 3)       # Set SFI

        # Write new values (need to stop electrode sensing first)
        mpr121._i2c_device.write(bytes([0x5E, 0x00]))  # Stop (ECR = 0)
        time.sleep(0.01)
        mpr121._i2c_device.write(bytes([MPR121_CONFIG1, new_config1]))
        mpr121._i2c_device.write(bytes([MPR121_CONFIG2, new_config2]))
        mpr121._i2c_device.write(bytes([0x5E, 0x8F]))  # Restart (ECR = 0x8F, baseline tracking + 12 electrodes)

        print(f"✓ MPR121 filters configured: CONFIG1=0x{new_config1:02X}, CONFIG2=0x{new_config2:02X}")
        print("  (FFI_10, SFI_10, CDT_4US - optimized for plant capacitance)")

    except Exception as e:
        print(f"⚠ Warning: Could not configure MPR121 filters: {e}")
        print("  Continuing with default filter settings...")


def initialize_mpr121_with_retry():
    """Initialize MPR121 with automatic retry and I2C reset on failure."""
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            print(f"Initializing MPR121 (attempt {attempt}/{MAX_RETRIES})...")
            i2c = busio.I2C(board.SCL, board.SDA)
            mpr121 = adafruit_mpr121.MPR121(i2c)

            # Configure advanced filter settings (FFI, SFI, CDT) for plant sensing
            configure_mpr121_filters(mpr121)

            # Configure hardware thresholds from config
            for i in range(12):
                mpr121[i].threshold = HW_TOUCH_THRESHOLD[i]
                mpr121[i].release_threshold = HW_RELEASE_THRESHOLD[i]

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
last_sent_values = [None] * 12
OSC_SEND_THRESHOLD = 0.3  # Only send OSC if value changed by this much

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


def calibrate_sensors(duration=10.0):
    """
    Calibrate sensors by finding minimum idle raw values over duration seconds.
    trigger_threshold = lowest_raw_value - CALIBRATION_BUFFER
    Returns calibrated RAW_MAX array.
    """
    global is_calibrating
    is_calibrating = True
    buffer = CALIBRATION_BUFFER
    print(f"\n=== CALIBRATION MODE ===")
    print(f"Sampling sensors for {duration} seconds (buffer={buffer})...")
    print("Please keep hands OFF all sensors!\n")
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

    # Store raw idle minimums and calculate trigger_threshold = raw_idle - buffer
    global RAW_MAX, RAW_IDLE
    for i in range(12):
        if min_values[i] != float('inf'):
            RAW_IDLE[i] = int(min_values[i])
    calibrated_max = [max(int(idle - buffer), 0) if idle is not None else 0 for idle in RAW_IDLE]
    RAW_MAX = calibrated_max

    print(f"Calibration complete! ({sample_count} samples)\n")
    print("Detected calibrated values per sensor:")
    for i in range(12):
        print(f"  sensor_{i}: raw_idle={RAW_IDLE[i]}, trigger_threshold={calibrated_max[i]} (idle - {buffer})")

    # Save only trigger_threshold to config — all other values are preserved as-is
    print("\n💾 Saving calibrated trigger_thresholds to config...")
    save_calibration_thresholds()

    is_calibrating = False
    return calibrated_max


def save_calibration_thresholds():
    """
    Save ONLY trigger_threshold values from calibration back to config.
    All other values (max_pressure, touch_threshold, release_threshold,
    calibration_interval_hours) are read from the existing config file and preserved.
    This means any manual edits are never overwritten by a calibration run.
    """
    try:
        with config_lock:
            # Read existing config to preserve all non-calibration values
            existing = {}
            if os.path.exists(CONFIG_FILE) and os.path.getsize(CONFIG_FILE) > 0:
                with open(CONFIG_FILE, 'r') as f:
                    existing = json.load(f)

            # Update trigger_threshold and raw_idle per sensor
            # raw_idle is stored so changing calibration_buffer instantly recomputes thresholds
            for i in range(12):
                sensor_key = f"sensor_{i}"
                if sensor_key not in existing:
                    existing[sensor_key] = {}
                existing[sensor_key]["trigger_threshold"] = int(RAW_MAX[i])
                if RAW_IDLE[i] is not None:
                    existing[sensor_key]["raw_idle"] = int(RAW_IDLE[i])

            with open(CONFIG_FILE, 'w') as f:
                json.dump(existing, f, indent=2)

        print(f"✓ Calibration (trigger_threshold) saved to {CONFIG_FILE}")
        return True

    except Exception as e:
        print(f"⚠ Error saving calibration: {e}")
        return False


def start_calibration_timer():
    """
    Background thread that runs periodic auto-calibration.
    Checks every minute whether the interval has elapsed.
    If CALIBRATION_INTERVAL_HOURS is 0, skips calibration (startup-only mode).
    Picks up config changes dynamically — no restart needed.
    """
    global _last_calibration_time

    def calibration_loop():
        global _last_calibration_time
        while True:
            time.sleep(60)  # Check every minute

            if CALIBRATION_INTERVAL_HOURS <= 0:
                continue

            now = time.time()
            # If never calibrated in this session, set reference from now
            ref = _last_calibration_time if _last_calibration_time else now
            elapsed_hours = (now - ref) / 3600

            if elapsed_hours >= CALIBRATION_INTERVAL_HOURS:
                print(f"\n⏰ Scheduled auto-calibration (every {CALIBRATION_INTERVAL_HOURS}h)...")
                calibrate_sensors()
                _last_calibration_time = time.time()

    t = threading.Thread(target=calibration_loop, daemon=True)
    t.start()
    if CALIBRATION_INTERVAL_HOURS > 0:
        print(f"⏰ Periodic calibration scheduled every {CALIBRATION_INTERVAL_HOURS}h")
    else:
        print("⏰ Calibration: startup only (set calibration_interval_hours in config to enable periodic)")


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
    RAW_MAX = calibrate_sensors()


def handle_hw_touch(address, *args):
    """Handle /sensorX/hw_touch messages to set hardware touch threshold."""
    try:
        sensor_num = int(address.split('/')[1].replace('sensor', ''))
        if 0 <= sensor_num <= 11 and len(args) > 0:
            new_threshold = int(args[0])
            if 0 <= new_threshold <= 255:
                HW_TOUCH_THRESHOLD[sensor_num] = new_threshold
                mpr121[sensor_num].threshold = new_threshold
                print(f"📥 OSC: sensor_{sensor_num} touch_threshold = {new_threshold}")
                save_config()
    except Exception as e:
        print(f"⚠ Error handling {address}: {e}")


def handle_hw_release(address, *args):
    """Handle /sensorX/hw_release messages to set hardware release threshold."""
    try:
        sensor_num = int(address.split('/')[1].replace('sensor', ''))
        if 0 <= sensor_num <= 11 and len(args) > 0:
            new_threshold = int(args[0])
            if 0 <= new_threshold <= 255:
                HW_RELEASE_THRESHOLD[sensor_num] = new_threshold
                mpr121[sensor_num].release_threshold = new_threshold
                print(f"📥 OSC: sensor_{sensor_num} release_threshold = {new_threshold}")
                save_config()
    except Exception as e:
        print(f"⚠ Error handling {address}: {e}")


def apply_hardware_thresholds():
    """Apply hardware thresholds to MPR121 chip (call after config load)."""
    global mpr121
    for i in range(12):
        mpr121[i].threshold = HW_TOUCH_THRESHOLD[i]
        mpr121[i].release_threshold = HW_RELEASE_THRESHOLD[i]

    print(f"✓ Hardware thresholds applied to MPR121")


def start_osc_server():
    """Start OSC server for receiving control messages."""
    dispatcher = Dispatcher()

    # Map OSC addresses to handlers
    for i in range(12):
        # Software thresholds
        dispatcher.map(f"/sensor{i}/pressure", handle_sensor_min)
        dispatcher.map(f"/sensor{i}/trigger", handle_sensor_max)
        # Hardware thresholds
        dispatcher.map(f"/sensor{i}/hw_touch", handle_hw_touch)
        dispatcher.map(f"/sensor{i}/hw_release", handle_hw_release)

    dispatcher.map("/recalibrate", handle_recalibrate)

    # Start server on port 57121 (different from SuperCollider's 57120)
    server = ThreadingOSCUDPServer(("0.0.0.0", 57121), dispatcher)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    print(f"🎛 OSC Control Server listening on port 57121")
    print("   Software thresholds:")
    print("     /sensorX/pressure <value>   - Max pressure point (e.g., /sensor9/pressure 45)")
    print("     /sensorX/trigger <value>    - Trigger threshold (e.g., /sensor9/trigger 90)")
    print("   Hardware sensitivity (0-255, lower=more sensitive):")
    print("     /sensorX/hw_touch <value>   - Touch threshold (e.g., /sensor10/hw_touch 12)")
    print("     /sensorX/hw_release <value> - Release threshold (e.g., /sensor10/hw_release 6)")
    print("   Calibration:")
    print("     /recalibrate                - Run auto-calibration")
    return server


try:
    print(f"OSC Client ready: {osc_ip}:{osc_port}")

    # Load config first to get max_pressure, hardware thresholds, and calibration interval
    # (trigger_threshold from config is ignored — we always calibrate fresh on boot)
    if load_config():
        apply_hardware_thresholds()
    else:
        print("ℹ No config file yet — will be created after calibration")

    # Always calibrate idle values fresh on startup regardless of config
    print("🔧 Running startup calibration (current idle values)...")
    calibrate_sensors()

    # Start config file watcher for hot-reload
    config_observer = start_config_watcher()

    # Start OSC control server
    osc_server = start_osc_server()

    # Start periodic calibration timer (picks up calibration_interval_hours from config)
    start_calibration_timer()

    client.send_message("/masterVol", MASTER_VOLUME)
    print(f"masterVol sent: {MASTER_VOLUME}")
    print("\nStarting main loop... Press Ctrl+C to exit.\n")
    
    consecutive_errors = 0
    MAX_CONSECUTIVE_ERRORS = 10

    while True:
        try:
            # Pause polling during calibration to avoid I2C conflicts
            if is_calibrating:
                time.sleep(0.1)
                continue

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

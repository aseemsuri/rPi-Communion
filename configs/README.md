# Deployment profiles

One codebase (`communion_python_cl1.py`), behavior selected by which profile you load.
Deploying = copy a profile over the active config, then set this box's `node_id`.

```bash
cp configs/rods_proximity.json python/sensor_config.json
# edit "node_id": "csn1"  ->  csn2, csn3, ... per box
sudo systemctl restart communion-python   # (or reboot)
```

| Profile | Sensing | Audio | OSC target | Setup script |
|---|---|---|---|---|
| `rods_proximity.json` | proximity + touch (`proximity_sensors:[9,11]`, CDT_8µs) | none | Mac (`/csn#/touchN`) | `setup_sensor_node.sh` |
| `altar_touch.json` | touch only (`proximity_sensors:[]`, CDT_32µs) | none | Mac (`/csn#/touchN`) | `setup_sensor_node.sh` |
| `garden_standalone.json` | touch only (CDT_32µs) | **on the Pi** | local SC (bare `/touchN`, `node_id:""`) | `setup_new_pi.sh` |

Notes:
- **Sensor nodes** (`rods`, `altar`) run only the `communion-python` service. `setup_sensor_node.sh` installs no SuperCollider/JACK and enables only that service.
- **Standalone** (`garden`) runs the full audio build — use `setup_new_pi.sh` and enable both services.
- Register values (CDT etc.) apply at script start — **restart** the service after changing them, not just hot-reload.
- Calibration ships zeroed; each box calibrates fresh on boot. Re-tune per hardware.
- `altar_touch` is reconstructed from the `TightTouch` branch and omits its MPR121 auto-config — expect to re-tune. Full register menu: `../MPR121_REGISTER_REFERENCE.md`.

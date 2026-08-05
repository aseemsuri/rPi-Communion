# Deployment profiles

One codebase (`communion_python_cl1.py`), behavior selected by which profile you load.
Deploying = copy a profile over the active config, then set this box's `node_id`.

```bash
cp configs/rods_proximity.json python/sensor_config.json
# edit "node_id": "csn1"  ->  csn2, csn3, ... per box
sudo systemctl restart communion-python   # (or reboot)
```

| Profile | Electrodes | Sensing | Audio | OSC target | Setup script |
|---|---|---|---|---|---|
| `rods_proximity.json` | `[11]` | proximity + touch, CDT_8µs (big floor rod) | none | Mac (`/csn#/touchN`) | `setup_sensor_node.sh` |
| `hanging.json` | `[0,6,11]` | proximity + touch, CDT_4µs (ceiling-hung rods) | none | Mac (`/csnh#/touchN`) | `setup_sensor_node.sh` |
| `altar_touch.json` | `[6..11]` | touch only (`proximity_sensors:[]`), CDT_32µs | none | Mac (`/csn#/touchN`) | `setup_sensor_node.sh` |
| `garden_standalone.json` | all 12 | touch only, CDT_32µs | **on the Pi** | local SC (bare `/touchN`, `node_id:""`) | `setup_new_pi.sh` |

Notes:
- **`active_sensors` is the electrode whitelist** — only these are polled and sent. An
  unconnected electrode floats at ~1023 (10-bit full scale) and still costs a full I2C
  transaction every pass, so polling all 12 on a sparsely-wired node causes bus I/O
  errors. Set it to exactly what is wired. Omitting the key falls back to `[11]` in code.
  Calibration still sweeps all 12, so the sensor table stays complete either way.
- **Sensor nodes** (`rods`, `hanging`, `altar`) run only the `communion-python` service. `setup_sensor_node.sh` installs no SuperCollider/JACK and enables only that service.
- **Standalone** (`garden`) runs the full audio build — use `setup_new_pi.sh` and enable both services.
- Register values (CDT etc.) apply at script start — **restart** the service after changing them, not just hot-reload.
- Calibration ships zeroed; each box calibrates fresh on boot. Re-tune per hardware.
- `altar_touch` is reconstructed from the `TightTouch` branch and omits its MPR121 auto-config — expect to re-tune. Full register menu: `../MPR121_REGISTER_REFERENCE.md`.

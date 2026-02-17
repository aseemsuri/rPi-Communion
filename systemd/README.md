# Communion Systemd Services

This directory contains systemd service files for running the Communion project as auto-restarting system services.

## Benefits

- **Auto-start on boot** - Services start automatically when Pi boots
- **Auto-restart on crash** - If scripts crash, systemd restarts them
- **Easy management** - Simple commands to start/stop/restart
- **Centralized logging** - All logs go to systemd journal
- **Background operation** - No need to keep SSH sessions open

## Files

- `communion-python.service` - Python MPR121 sensor service
- `communion-sc.service` - SuperCollider audio engine service
- `setup-services.sh` - One-time setup script
- `manage.sh` - Convenience script for daily management
- `README.md` - This file

## Initial Setup

### 1. Run the setup script (ONE TIME):

```bash
cd ~/communion-project
bash systemd/setup-services.sh
```

This will:
- Create sudoers rule for I2C bus reset
- Copy service files to `/etc/systemd/system/`
- Enable services for auto-start on boot

### 2. Start the services:

```bash
sudo systemctl start communion-python communion-sc
```

### 3. Check status:

```bash
sudo systemctl status communion-python communion-sc
```

## Daily Usage

### Using the management script:

```bash
cd ~/communion-project

# Start services
./systemd/manage.sh start

# Stop services
./systemd/manage.sh stop

# Restart after code changes
./systemd/manage.sh restart

# Check status
./systemd/manage.sh status

# View Python logs (live)
./systemd/manage.sh logs

# View SuperCollider logs (live)
./systemd/manage.sh logs sc

# View both logs together
./systemd/manage.sh logs-both
```

### Using systemctl directly:

```bash
# Start
sudo systemctl start communion-python
sudo systemctl start communion-sc

# Stop
sudo systemctl stop communion-python
sudo systemctl stop communion-sc

# Restart (after code changes)
sudo systemctl restart communion-python
sudo systemctl restart communion-sc

# Status
sudo systemctl status communion-python
sudo systemctl status communion-sc

# View logs
journalctl -u communion-python -f
journalctl -u communion-sc -f
journalctl -u communion-python -u communion-sc -f  # both
```

## Development Workflow

Your workflow stays the same - edit, commit, pull, restart:

### On your Mac:
```bash
# Edit scripts via sshfs mount
# Commit and push changes
git add .
git commit -m "Add new sensor"
git push
```

### On the Pi:
```bash
# Pull latest code
cd ~/communion-project
git pull

# Restart services to use new code
./systemd/manage.sh restart

# Watch logs to verify
./systemd/manage.sh logs-both
```

## Service Details

### Python Service
- Runs with virtual environment `/home/pi/mpr121-env`
- Has permissions to reset I2C bus (via sudoers)
- Restarts automatically after 10 seconds on crash
- Logs to systemd journal

### SuperCollider Service
- Uses `xvfb-run` for headless operation
- Starts after Python service (ensures OSC is ready)
- Auto-restarts on JACK errors
- Cleans up JACK and sclang processes on stop
- Logs to systemd journal

## Troubleshooting

### Check if services are running:
```bash
./systemd/manage.sh status
```

### View recent errors:
```bash
journalctl -u communion-python --since "10 minutes ago"
journalctl -u communion-sc --since "10 minutes ago"
```

### Restart if JACK has issues:
```bash
./systemd/manage.sh restart
```

### Stop services temporarily:
```bash
./systemd/manage.sh stop
```

### Disable auto-start on boot:
```bash
./systemd/manage.sh disable
```

## Logs

View logs with timestamps:
```bash
journalctl -u communion-python -f
```

View logs from last hour:
```bash
journalctl -u communion-python --since "1 hour ago"
```

View logs from today:
```bash
journalctl -u communion-python --since today
```

Save logs to file:
```bash
journalctl -u communion-python -u communion-sc > ~/communion-logs.txt
```

## Uninstall

To remove the services:

```bash
# Stop and disable services
sudo systemctl stop communion-python communion-sc
sudo systemctl disable communion-python communion-sc

# Remove service files
sudo rm /etc/systemd/system/communion-python.service
sudo rm /etc/systemd/system/communion-sc.service

# Remove sudoers rule
sudo rm /etc/sudoers.d/communion-i2c

# Reload systemd
sudo systemctl daemon-reload
```

## Notes

- Services point to files in the git repo, so code changes are immediately available after restart
- No need for separate branches or deployment - just edit, commit, pull, restart
- The old `run_python.sh` and `run_supercollider.sh` scripts still work if you want to run manually
- Services auto-restart means your installation keeps running even through errors and power cycles

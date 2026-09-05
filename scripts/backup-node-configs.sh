#!/bin/bash
# Capture each node's sensor_config.json (gitignored, lives only on the SD card)
# into real Dropbox storage. Reads the fuse-t NFS mounts, so it only sees nodes
# that are powered on and mounted — unreachable nodes are skipped silently.
SRC="/Users/aseemsuri/Dropbox/STUDIO/Communion"
DST="$SRC/_backups/configs"
STAMP=$(date +%Y-%m-%d_%H%M)
mkdir -p "$DST/latest" "$DST/history/$STAMP"
found=0; changed=0
for d in "$SRC"/CSN*/ "$SRC"/SCN/; do
  node=$(basename "$d")
  f="${d}python/sensor_config.json"
  [ -f "$f" ] || continue
  # absolute path: launchd's PATH is minimal, bare python3 may not resolve.
  # retry once, NFS reads can transiently come back short.
  PY=/usr/bin/python3
  if ! "$PY" -c "import json,sys;json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    sleep 2
    if ! "$PY" -c "import json,sys;json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
      echo "  SKIP $node — unreadable after retry"; continue
    fi
  fi
  if ! cmp -s "$f" "$DST/latest/$node.json" 2>/dev/null; then
    cp "$f" "$DST/history/$STAMP/$node.json"; echo "  changed: $node"; changed=$((changed+1))
  fi
  cp "$f" "$DST/latest/$node.json"; found=$((found+1))
done
rmdir "$DST/history/$STAMP" 2>/dev/null
echo "$STAMP — $found node(s) captured, $changed changed"

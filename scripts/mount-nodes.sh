#!/bin/bash
# Mount all Communion nodes over sshfs.  Usage: ./mount-nodes.sh
# Unmount everything with: ./mount-nodes.sh -u

USER=pi
REMOTE=communion-project          # path on the Pi, relative to its home dir
BASE=/Users/aseemsuri/Dropbox/STUDIO/Communion

# name:ip
NODES="csn1:51 csn2:52 csn3:53 csn4:54 csn5:55 csn6:56 csn7:57 csn8:58 csna1:41"

if [ "$1" = "-u" ]; then
    for n in $NODES; do
        name="${n%%:*}"
        umount "$BASE/$name" 2>/dev/null && echo "  unmounted $name"
    done
    exit 0
fi

for n in $NODES; do
    name="${n%%:*}"; last="${n##*:}"
    ip="192.168.8.$last"
    mkdir -p "$BASE/$name"
    if mount | grep -q "$BASE/$name"; then
        echo "  $name already mounted"; continue
    fi
    if sshfs "$USER@$ip:$REMOTE" "$BASE/$name" \
        -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,volname="$name"
    then echo "  ✓ $name  ($ip)"
    else echo "  ✗ $name  ($ip) — not reachable or wrong path"
    fi
done

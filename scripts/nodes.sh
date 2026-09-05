#!/bin/bash
# Run a command on some or all Communion nodes.
#
#   nodes.sh restart                     every node
#   nodes.sh -n rods restart             csn1-8, skip the altar
#   nodes.sh -n corners restart          csn1-4
#   nodes.sh -n csn2,csn6 log            just those two
#   nodes.sh -x csna1 pull               everything EXCEPT the altar
#   nodes.sh -n interior 'uptime'        any shell command
#
# groups:  all  rods  corners  interior  altar
# ---------------------------------------------------------------------------
USER=pi

ip_for() {
    case "$1" in
        csna1) echo 41 ;;  csn1) echo 51 ;;  csn2) echo 52 ;;
        csn3)  echo 53 ;;  csn4) echo 54 ;;  csn5) echo 55 ;;
        csn6)  echo 56 ;;  csn7) echo 57 ;;  csn8) echo 58 ;;
        *) echo "" ;;
    esac
}

ALL="csna1 csn1 csn2 csn3 csn4 csn5 csn6 csn7 csn8"

expand() {   # group name or comma list -> space-separated node names
    case "$1" in
        all)      echo "$ALL" ;;
        rods)     echo "csn1 csn2 csn3 csn4 csn5 csn6 csn7 csn8" ;;
        corners)  echo "csn1 csn2 csn3 csn4" ;;   # edit to match the room
        interior) echo "csn5 csn6 csn7 csn8" ;;
        altar)    echo "csna1" ;;
        *)        echo "$1" | tr ',' ' ' ;;
    esac
}

SEL="all"; EXCL=""
while true; do
    case "$1" in
        -n) SEL="$2";  shift 2 ;;
        -x) EXCL="$2"; shift 2 ;;
        *)  break ;;
    esac
done

case "$1" in
  restart)  CMD='sudo systemctl restart communion-python && systemctl is-active communion-python' ;;
  status)   CMD='systemctl is-active communion-python' ;;
  pull)     CMD='cd ~/communion-project && git pull -q && sudo systemctl restart communion-python && echo pulled+restarted' ;;
  log)      CMD='journalctl -u communion-python -n 15 --no-pager' ;;
  shutdown) CMD='sudo shutdown -h now' ;;
  "")       echo "usage: nodes.sh [-n group|list] [-x list] <restart|status|pull|log|shutdown|'command'>"
            echo "groups: all rods corners interior altar"; exit 1 ;;
  *)        CMD="$1" ;;
esac

NODES=$(expand "$SEL")
if [ -n "$EXCL" ]; then
    for drop in $(expand "$EXCL"); do
        NODES=$(echo " $NODES " | sed "s/ $drop / /g")
    done
fi

for name in $NODES; do
    last=$(ip_for "$name")
    if [ -z "$last" ]; then echo "  ?? unknown node: $name"; continue; fi
    ip="192.168.8.$last"
    printf "\033[1m--- %-6s %-14s\033[0m " "$name" "$ip"
    out=$(ssh -o ConnectTimeout=6 -o BatchMode=yes "$USER@$ip" "$CMD" 2>&1)
    rc=$?
    if [ $rc -ne 0 ] && [ -z "$out" ]; then echo "UNREACHABLE"; continue; fi
    if [ "$(echo "$out" | wc -l)" -le 1 ]; then echo "$out"
    else echo; echo "$out" | sed 's/^/      /'
    fi
done

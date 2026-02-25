#!/bin/bash

# Stop all port forwardlers

PID_DIR="/tmp/socat-forwards"

if [ ! -d "$PID_DIR" ]; then
    echo "No port forwarders running (PID directory not found)"
    exit 0
fi

# Find all PID files
PID_FILES=("$PID_DIR"/*.pid)

if [ ! -e "${PID_FILES[0]}" ]; then
    echo "No port forwarders running (no PID files found)"
    exit 0
fi

echo "Stopping port forwarders..."
echo ""

STOPPED_COUNT=0
STALE_COUNT=0

for pid_file in "${PID_FILES[@]}"; do
    [ -f "$pid_file" ] || continue

    pid=$(cat "$pid_file")
    port=$(basename "$pid_file" .pid | sed 's/socat-//')

    if ps -p "$pid" > /dev/null 2>&1; then
        echo "  Stopping port $port (PID: $pid)..."
        kill "$pid" 2>/dev/null
        sleep 0.5

        # Force kill if still running
        if ps -p "$pid" > /dev/null 2>&1; then
            kill -9 "$pid" 2>/dev/null
        fi

        rm -f "$pid_file"
        echo "  ✓ Port $port stopped"
        ((STOPPED_COUNT++))
    else
        echo "  ⚠ Port $port not running (stale PID file)"
        rm -f "$pid_file"
        ((STALE_COUNT++))
    fi
done

echo ""
echo "=== Summary ==="
echo "Stopped: $STOPPED_COUNT"
if [ $STALE_COUNT -gt 0 ]; then
    echo "Stale PIDs cleaned: $STALE_COUNT"
fi

# Clean up empty directory
if [ -z "$(ls -A $PID_DIR 2>/dev/null)" ]; then
    rmdir "$PID_DIR" 2>/dev/null
fi


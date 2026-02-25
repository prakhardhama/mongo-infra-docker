#!/bin/bash

# Check the status of all port forwarders

PID_DIR="/tmp/socat-forwards"
LOG_DIR="/tmp/socat-forwards"

echo "=== Port Forwarder Status ==="
echo ""

if [ ! -d "$PID_DIR" ]; then
    echo "Status: ✗ NOT RUNNING"
    echo "Run ./scripts/start-port-forward.sh to start"
    exit 0
fi

# Find all PID files
PID_FILES=("$PID_DIR"/*.pid)

if [ ! -e "${PID_FILES[0]}" ]; then
    echo "Status: ✗ NOT RUNNING"
    echo "Run ./scripts/start-port-forward.sh to start"
    exit 0
fi

RUNNING_COUNT=0
STALE_COUNT=0

echo "Active Port Forwards:"
echo ""

for pid_file in "${PID_FILES[@]}"; do
    [ -f "$pid_file" ] || continue

    pid=$(cat "$pid_file")
    port=$(basename "$pid_file" .pid | sed 's/socat-//')

    if ps -p "$pid" > /dev/null 2>&1; then
        # Get the full command to extract target
        cmd=$(ps -p "$pid" -o command= | grep -o 'TCP:[^ ]*' | tail -1 | sed 's/TCP://')

        echo "  ✓ Port $port -> $cmd"
        echo "    PID: $pid"
        echo "    Uptime: $(ps -p "$pid" -o etime= | xargs)"
        echo "    Log: $LOG_DIR/socat-${port}.log"
        echo ""
        ((RUNNING_COUNT++))
    else
        echo "  ✗ Port $port (stale PID file)"
        echo ""
        ((STALE_COUNT++))
    fi
done

echo "=== Summary ==="
echo "Running: $RUNNING_COUNT"
if [ $STALE_COUNT -gt 0 ]; then
    echo "Stale: $STALE_COUNT (run stop script to clean up)"
fi
echo ""

# Show all listening ports
if [ $RUNNING_COUNT -gt 0 ]; then
    echo "=== Port Listeners ==="
    for pid_file in "${PID_FILES[@]}"; do
        [ -f "$pid_file" ] || continue
        pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            port=$(basename "$pid_file" .pid | sed 's/socat-//')
            lsof -Pi :$port -sTCP:LISTEN 2>/dev/null | head -2
        fi
    done
    echo ""
fi

# Connection test for MongoDB port (27017) if it's being forwarded
if [ -f "$PID_DIR/socat-27017.pid" ]; then
    pid=$(cat "$PID_DIR/socat-27017.pid")
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "=== MongoDB Connection Test ==="
        if command -v mongosh &> /dev/null; then
            if mongosh "mongodb://127.0.0.1:27017/?directConnection=true" --quiet --eval "print('✓ Connection to localhost:27017 successful')" 2>/dev/null; then
                :
            else
                echo "✗ Cannot connect to localhost:27017"
            fi
        else
            echo "⚠ mongosh not found, skipping connection test"
        fi
        echo ""
    fi
fi

if [ $RUNNING_COUNT -eq 0 ]; then
    echo "Run ./scripts/start-port-forward.sh to start port forwarding"
fi


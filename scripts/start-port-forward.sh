#!/bin/bash

# Multi-Port Forwarder using socat
# Forwards multiple ports as configured in PORT_MAPPINGS

# Configuration: Array of "listen_port:target_host:target_port" mappings
# Add or remove mappings as needed
PORT_MAPPINGS=(
    "27017:127.0.0.1:27171"  # MongoDB replica set
    # Add more mappings here, e.g.:
    # "8080:127.0.0.1:8081"
    # "3000:127.0.0.1:3001"
)

PID_DIR="/tmp/socat-forwards"
LOG_DIR="/tmp/socat-forwards"

# Create directories if they don't exist
mkdir -p "$PID_DIR" "$LOG_DIR"

# Function to check if a port is in use
check_port_in_use() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 0  # Port is in use
    else
        return 1  # Port is free
    fi
}

# Function to start a single port forward
start_forward() {
    local mapping=$1
    local listen_port=$(echo $mapping | cut -d: -f1)
    local target_host=$(echo $mapping | cut -d: -f2)
    local target_port=$(echo $mapping | cut -d: -f3)

    local pid_file="$PID_DIR/socat-${listen_port}.pid"
    local log_file="$LOG_DIR/socat-${listen_port}.log"

    # Check if already running
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "  ⚠ Port $listen_port forwarder already running (PID: $pid)"
            return 0
        else
            rm -f "$pid_file"
        fi
    fi

    # Check if port is in use by another process
    if check_port_in_use $listen_port; then
        echo "  ✗ Port $listen_port is already in use by another process:"
        lsof -Pi :$listen_port -sTCP:LISTEN | grep -v COMMAND
        return 1
    fi

    # Get the directory where this script is located
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Start socat using the daemon wrapper
    "$script_dir/daemon-wrapper.sh" "$listen_port" "$target_host" "$target_port" "$log_file" &
    local pid=$!

    # Disown the process to detach it from the shell
    disown $pid 2>/dev/null || true

    # Save PID
    echo $pid > "$pid_file"

    # Verify it started
    sleep 0.5
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "  ✓ localhost:$listen_port -> $target_host:$target_port (PID: $pid)"
        return 0
    else
        echo "  ✗ Failed to start forwarder for port $listen_port"
        echo "    Process died immediately. Check log: $log_file"
        rm -f "$pid_file"
        return 1
    fi
}

# Main execution
echo "Starting port forwarders..."
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

for mapping in "${PORT_MAPPINGS[@]}"; do
    # Skip empty lines and comments
    [[ -z "$mapping" || "$mapping" =~ ^[[:space:]]*# ]] && continue

    if start_forward "$mapping"; then
        ((SUCCESS_COUNT++))
    else
        ((FAIL_COUNT++))
    fi
done

echo ""
echo "=== Summary ==="
echo "Started: $SUCCESS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ $SUCCESS_COUNT -gt 0 ]; then
    echo "To stop: ./scripts/stop-port-forward.sh"
    echo "To check status: ./scripts/status-port-forward.sh"
    echo ""
    echo "PID files: $PID_DIR/"
    echo "Log files: $LOG_DIR/"
fi

exit $FAIL_COUNT


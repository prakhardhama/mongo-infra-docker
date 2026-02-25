#!/bin/bash

# Daemon wrapper for socat
# This script is designed to be run in the background and stay alive

LISTEN_PORT=$1
TARGET_HOST=$2
TARGET_PORT=$3
LOG_FILE=$4

if [ -z "$LISTEN_PORT" ] || [ -z "$TARGET_HOST" ] || [ -z "$TARGET_PORT" ] || [ -z "$LOG_FILE" ]; then
    echo "Usage: $0 <listen_port> <target_host> <target_port> <log_file>"
    exit 1
fi

# Redirect all output to log file
exec >> "$LOG_FILE" 2>&1

# Close stdin
exec </dev/null

# Run socat
exec socat TCP-LISTEN:$LISTEN_PORT,fork,reuseaddr TCP:$TARGET_HOST:$TARGET_PORT


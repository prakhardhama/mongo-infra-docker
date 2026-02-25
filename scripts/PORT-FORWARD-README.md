# Multi-Port Forwarder

## Overview

This directory contains scripts to manage port forwarding for services running in Docker. The scripts support **multiple port mappings** simultaneously.

### Why Port Forwarding is Needed

For the MongoDB replica set:

1. **Meta OM** (in Docker) deploys a MongoDB replica set on `node1.om.internal:27017`
2. The Docker container exposes this as `localhost:27171` on the host
3. **Primary OM** (running locally via Bazel) needs to connect to this replica set
4. MongoDB's replica set discovery returns `node1.om.internal:27017` as the member address
5. The port forwarder maps `localhost:27017` → `localhost:27171` to handle this

You can easily add more port mappings for other services as needed.

## Scripts

### `start-port-forward.sh`
Starts all configured port forwarders in the background.

```bash
./scripts/start-port-forward.sh
```

**What it does:**
- Reads port mappings from the `PORT_MAPPINGS` array in the script
- For each mapping, checks if the port is available
- Starts a separate socat process for each port forward
- Saves PIDs to `/tmp/socat-forwards/socat-{port}.pid`
- Logs output to `/tmp/socat-forwards/socat-{port}.log`

### `stop-port-forward.sh`
Stops all running port forwarders.

```bash
./scripts/stop-port-forward.sh
```

**What it does:**
- Finds all running port forwarders
- Gracefully stops each one (with force kill if needed)
- Cleans up PID files

### `status-port-forward.sh`
Shows the current status of all port forwarders and tests connections.

```bash
./scripts/status-port-forward.sh
```

**What it shows:**
- List of all active port forwards with PIDs and uptime
- Port listener information
- MongoDB connection test (if port 27017 is forwarded)

## Usage

### Starting the Primary OM

Before running the primary OM with Bazel, make sure the port forwarder is running:

```bash
# 1. Start the port forwarder
cd /Users/prakhar.dhama/mongo-infra-docker
./scripts/start-port-forward.sh

# 2. Verify it's working
./scripts/status-port-forward.sh

# 3. Run the primary OM
cd /Users/prakhar.dhama/ops-manager
bazel run --server_env=hosted //server:mms
```

### Stopping Everything

```bash
# Stop the port forwarder
cd /Users/prakhar.dhama/mongo-infra-docker
./scripts/stop-port-forward.sh
```

## Configuration

### Adding Port Mappings

Edit the `PORT_MAPPINGS` array in `start-port-forward.sh`:

```bash
PORT_MAPPINGS=(
    "27017:127.0.0.1:27171"  # MongoDB replica set
    "8080:127.0.0.1:8081"    # Example: Web service
    "3000:127.0.0.1:3001"    # Example: API service
)
```

**Format:** `"listen_port:target_host:target_port"`

- **listen_port**: Port on localhost that clients connect to
- **target_host**: Usually `127.0.0.1` (localhost)
- **target_port**: The actual port where the service is running (e.g., Docker mapped port)

### Current Configuration

By default, only MongoDB port forwarding is configured:

- **27017** → **127.0.0.1:27171** (MongoDB replica set)

## Troubleshooting

### Port already in use

If you get an error that a port is already in use:

```bash
# Find what's using the port (e.g., port 27017)
lsof -Pi :27017 -sTCP:LISTEN

# Stop all port forwarders
./scripts/stop-port-forward.sh

# Or kill the specific process
kill <PID>
```

### Connection issues

Check the logs for a specific port:

```bash
# For port 27017
cat /tmp/socat-forwards/socat-27017.log

# List all logs
ls -lh /tmp/socat-forwards/
```

Test the connection manually:

```bash
# For MongoDB
mongosh "mongodb://127.0.0.1:27017/?directConnection=true" --eval "db.adminCommand({ping: 1})"

# For HTTP services
curl http://localhost:8080
```

### Viewing all active forwards

```bash
./scripts/status-port-forward.sh
```

## Requirements

- **socat**: Install with `brew install socat`
- **/etc/hosts** must have: `127.0.0.1 node1.om.internal`

## How It Works

```
Primary OM (Bazel)
    ↓
connects to: node1.om.internal:27017
    ↓
/etc/hosts resolves to: 127.0.0.1:27017
    ↓
socat forwards to: 127.0.0.1:27171
    ↓
Docker port mapping: container port 27017
    ↓
Meta OM's MongoDB replica set
```


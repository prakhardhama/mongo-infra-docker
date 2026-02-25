# Port Forwarder Examples

## Example 1: Single Port (Current Setup)

**Scenario:** Forward MongoDB replica set port

```bash
# In start-port-forward.sh
PORT_MAPPINGS=(
    "27017:127.0.0.1:27171"  # MongoDB replica set
)
```

**Usage:**
```bash
./scripts/start-port-forward.sh
./scripts/status-port-forward.sh
./scripts/stop-port-forward.sh
```

## Example 2: Multiple Ports

**Scenario:** Forward MongoDB + Ops Manager Web UI + API

```bash
# In start-port-forward.sh
PORT_MAPPINGS=(
    "27017:127.0.0.1:27171"  # MongoDB replica set
    "8080:127.0.0.1:8180"    # Ops Manager Web UI
    "8443:127.0.0.1:8543"    # Ops Manager API (HTTPS)
)
```

**Result:**
```
Starting port forwarders...

  ✓ localhost:27017 -> 127.0.0.1:27171 (PID: 1234)
  ✓ localhost:8080 -> 127.0.0.1:8180 (PID: 1235)
  ✓ localhost:8443 -> 127.0.0.1:8543 (PID: 1236)

=== Summary ===
Started: 3
Failed: 0
```

## Example 3: Development Environment

**Scenario:** Forward multiple services for local development

```bash
# In start-port-forward.sh
PORT_MAPPINGS=(
    "27017:127.0.0.1:27171"  # MongoDB
    "3000:127.0.0.1:3001"    # React dev server
    "5000:127.0.0.1:5001"    # API server
    "6379:127.0.0.1:6380"    # Redis
    "5432:127.0.0.1:5433"    # PostgreSQL
)
```

## Example 4: Conditional Forwarding

**Scenario:** Only forward certain ports based on environment

```bash
# In start-port-forward.sh
PORT_MAPPINGS=(
    "27017:127.0.0.1:27171"  # Always forward MongoDB
)

# Add additional ports based on environment variable
if [ "$FORWARD_WEB" = "true" ]; then
    PORT_MAPPINGS+=("8080:127.0.0.1:8180")
fi

if [ "$FORWARD_API" = "true" ]; then
    PORT_MAPPINGS+=("8443:127.0.0.1:8543")
fi
```

**Usage:**
```bash
# Forward only MongoDB
./scripts/start-port-forward.sh

# Forward MongoDB + Web UI
FORWARD_WEB=true ./scripts/start-port-forward.sh

# Forward all
FORWARD_WEB=true FORWARD_API=true ./scripts/start-port-forward.sh
```

## Testing Individual Ports

### MongoDB
```bash
mongosh "mongodb://127.0.0.1:27017/?directConnection=true" --eval "db.adminCommand({ping: 1})"
```

### HTTP Services
```bash
curl http://localhost:8080
curl -k https://localhost:8443
```

### TCP Services
```bash
nc -zv localhost 6379
telnet localhost 5432
```

## Troubleshooting

### Check which ports are being forwarded
```bash
./scripts/status-port-forward.sh
```

### Check logs for a specific port
```bash
cat /tmp/socat-forwards/socat-27017.log
cat /tmp/socat-forwards/socat-8080.log
```

### Stop a specific port forward
```bash
# Find the PID
cat /tmp/socat-forwards/socat-8080.pid

# Kill it
kill $(cat /tmp/socat-forwards/socat-8080.pid)

# Or stop all
./scripts/stop-port-forward.sh
```

### Restart after adding new ports
```bash
./scripts/stop-port-forward.sh
# Edit start-port-forward.sh to add new ports
./scripts/start-port-forward.sh
```


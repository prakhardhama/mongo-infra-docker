#!/bin/bash
set -e  # Exit on error

echo "=========================================="
echo "MongoDB Agent Restart Script"
echo "=========================================="
echo "Target: mongodb-ops-manager container"
echo ""

# Verify container is running
echo "==> Verifying container..."
if ! docker ps | grep -q "^.*mongodb-ops-manager"; then
    echo "ERROR: mongodb-ops-manager container is not running"
    exit 1
fi
echo "✓ Container is running"
echo ""

# Ensure mongod is running (container entrypoint is tail -f /dev/null)
echo "==> Checking mongod status..."
if ! docker exec mongodb-ops-manager pgrep -x mongod > /dev/null 2>&1; then
    echo "⚠️  mongod is not running — starting it..."
    docker exec -d mongodb-ops-manager mongod \
        --replSet appdb-rs --bind_ip 0.0.0.0 --port 27017 \
        --dbpath /data/db --logpath /var/log/mongodb/mongod.log --logappend
    echo "Waiting for mongod to be ready..."
    for i in $(seq 1 15); do
        if docker exec mongodb-ops-manager mongosh --quiet --eval "db.runCommand({ping:1})" > /dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    # Verify replica set can elect — reconfig if member host is stale
    RS_STATE=$(docker exec mongodb-ops-manager mongosh --quiet --eval "rs.status().members[0].stateStr" 2>/dev/null || echo "UNKNOWN")
    if [ "$RS_STATE" != "PRIMARY" ]; then
        echo "⚠️  Replica set member not PRIMARY (state: $RS_STATE) — force-reconfiguring..."
        docker exec mongodb-ops-manager mongosh --quiet --eval "
            var cfg = rs.conf();
            cfg.members[0].host = 'localhost:27017';
            cfg.version = cfg.version + 1;
            rs.reconfig(cfg, {force: true});
        "
        for i in $(seq 1 10); do
            RS_STATE=$(docker exec mongodb-ops-manager mongosh --quiet --eval "rs.status().members[0].stateStr" 2>/dev/null || echo "UNKNOWN")
            if [ "$RS_STATE" = "PRIMARY" ]; then break; fi
            sleep 1
        done
    fi
    if [ "$RS_STATE" = "PRIMARY" ]; then
        echo "✓ mongod started and replica set is PRIMARY"
    else
        echo "❌ ERROR: mongod started but replica set did not reach PRIMARY (state: $RS_STATE)"
        exit 1
    fi
else
    echo "✓ mongod is already running"
fi
echo ""

# Check if agent is already running
echo "==> Checking agent status..."
if docker exec mongodb-ops-manager pgrep -f mongodb-mms-automation-agent > /dev/null 2>&1; then
    echo "⚠️  Agent is already running!"
    echo ""
    echo "Current agent process:"
    docker exec mongodb-ops-manager pgrep -fa mongodb-mms-automation-agent
    echo ""
    read -p "Do you want to restart it anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Exiting without changes."
        exit 0
    fi
    echo ""
    echo "==> Stopping existing agent..."
    docker exec -u root mongodb-ops-manager pkill -f mongodb-mms-automation-agent || true
    sleep 2
    echo "✓ Agent stopped"
    echo ""
fi

# Verify agent binary exists
echo "==> Verifying agent installation..."
if ! docker exec mongodb-ops-manager test -f /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent; then
    echo "ERROR: Agent binary not found at /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent"
    echo ""
    echo "Please run the installation script first:"
    echo "  ./om-docker/meta-om-primary-appdb-agent-installation.sh"
    exit 1
fi
echo "✓ Agent binary found"
echo ""

# Verify agent configuration exists
echo "==> Verifying agent configuration..."
if ! docker exec mongodb-ops-manager test -f /etc/mongodb-mms/automation-agent.config; then
    echo "ERROR: Agent configuration not found at /etc/mongodb-mms/automation-agent.config"
    echo ""
    echo "Please run the installation script first:"
    echo "  ./om-docker/meta-om-primary-appdb-agent-installation.sh"
    exit 1
fi
echo "✓ Agent configuration found"
echo ""

# Display current configuration
echo "==> Current agent configuration:"
docker exec mongodb-ops-manager grep -E "mmsGroupId|mmsBaseUrl" /etc/mongodb-mms/automation-agent.config | sed 's/mmsApiKey=.*/mmsApiKey=***REDACTED***/'
echo ""

# Get container hostname
CONTAINER_HOSTNAME=$(docker inspect mongodb-ops-manager | jq -r '.[0].Config.Hostname')
echo "==> Container hostname: $CONTAINER_HOSTNAME"
echo ""

# Start the agent
echo "==> Starting automation agent..."
docker exec -u root mongodb-ops-manager bash -c "
  nohup /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent \
    -f /etc/mongodb-mms/automation-agent.config \
    >> /var/log/mongodb-mms-automation/agent-startup.log 2>&1 &
"

# Wait for agent to start
echo "Waiting for agent to start..."
sleep 5

# Verify agent is running
if docker exec mongodb-ops-manager pgrep -f mongodb-mms-automation-agent > /dev/null 2>&1; then
    echo "✓ Agent started successfully!"
    echo ""
    echo "Agent process:"
    docker exec mongodb-ops-manager pgrep -fa mongodb-mms-automation-agent
    echo ""
    echo "=========================================="
    echo "✅ SUCCESS!"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo "1. Wait 1-2 minutes for agent to connect to Meta OM"
    echo "2. Check Meta OM UI → Servers → $CONTAINER_HOSTNAME"
    echo "3. Verify Monitoring Agent is green ✅"
    echo "4. Verify Backup Agent is green ✅"
    echo ""
    echo "To view agent logs:"
    echo "  docker exec mongodb-ops-manager tail -f /var/log/mongodb-mms-automation/automation-agent.log"
    echo ""
else
    echo "❌ ERROR: Agent failed to start"
    echo ""
    echo "Check the logs:"
    echo "  docker exec mongodb-ops-manager tail -50 /var/log/mongodb-mms-automation/automation-agent.log"
    exit 1
fi


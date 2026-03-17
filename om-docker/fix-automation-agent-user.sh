#!/bin/bash
set -e

echo "=========================================="
echo "Fix Automation Agent User Mismatch"
echo "=========================================="
echo ""
echo "Problem: MongoDB runs as 'mongod' user, but automation agent runs as 'root'"
echo "Solution: Run automation agent as 'mongod' user"
echo ""

# Step 1: Stop the automation agent
echo "==> Stopping automation agent..."
docker exec -u root mongodb-ops-manager pkill -f mongodb-mms-automation-agent || true
sleep 2

# Verify it's stopped
if docker exec mongodb-ops-manager pgrep -f mongodb-mms-automation-agent > /dev/null; then
    echo "WARNING: Automation agent is still running, trying kill -9..."
    docker exec -u root mongodb-ops-manager pkill -9 -f mongodb-mms-automation-agent || true
    sleep 2
fi

if docker exec mongodb-ops-manager pgrep -f mongodb-mms-automation-agent > /dev/null; then
    echo "ERROR: Automation agent is still running"
    exit 1
fi
echo "✓ Automation agent stopped"
echo ""

# Step 2: Remove and recreate lock file with correct permissions
echo "==> Fixing lock file permissions..."
docker exec -u root mongodb-ops-manager rm -f /tmp/mongodb-mms-automation.lock
docker exec -u root mongodb-ops-manager touch /tmp/mongodb-mms-automation.lock
docker exec -u root mongodb-ops-manager chown mongod:mongod /tmp/mongodb-mms-automation.lock
docker exec -u root mongodb-ops-manager chmod 600 /tmp/mongodb-mms-automation.lock
echo "✓ Lock file permissions fixed"
echo ""

# Step 3: Change ownership of automation files to mongod user
echo "==> Changing ownership of automation files to 'mongod' user..."
docker exec -u root mongodb-ops-manager chown -R mongod:mongod /opt/mongodb-mms-automation
docker exec -u root mongodb-ops-manager chown -R mongod:mongod /etc/mongodb-mms
docker exec -u root mongodb-ops-manager chown -R mongod:mongod /var/log/mongodb-mms-automation
docker exec -u root mongodb-ops-manager chown -R mongod:mongod /var/lib/mongodb-mms-automation
echo "✓ Ownership changed"
echo ""

# Step 4: Restart automation agent as mongod user
echo "==> Starting automation agent as 'mongod' user..."
docker exec -d -u mongod mongodb-ops-manager \
  /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent \
  -f /etc/mongodb-mms/automation-agent.config

sleep 5

# Step 5: Verify it's running as mongod user
echo "==> Verifying automation agent is running as 'mongod' user..."
sleep 2
AGENT_USER=$(docker exec mongodb-ops-manager ps aux | grep mongodb-mms-automation-agent | grep -v grep | awk '{print $1}' | head -1)

if [ "$AGENT_USER" = "mongod" ]; then
    echo "✓ Automation agent is now running as 'mongod' user"
    echo ""
    echo "=========================================="
    echo "✅ SUCCESS!"
    echo "=========================================="
    echo ""
    echo "Both MongoDB and Automation Agent are now running as 'mongod' user."
    echo ""
    echo "Next steps:"
    echo "  1. Go back to Meta OM UI"
    echo "  2. Try the automation initialization again"
    echo "  3. The error should be resolved!"
    echo ""
else
    echo "ERROR: Automation agent is running as '$AGENT_USER' instead of 'mongod'"
    exit 1
fi

# Show current process users
echo "Current process users:"
docker exec mongodb-ops-manager ps aux | grep -E "mongod|automation-agent" | grep -v grep


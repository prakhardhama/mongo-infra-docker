#!/bin/bash

# Disaster Recovery PoC - Phase 3: Prepare for Automated Restore
# This script prepares the infrastructure so Meta OM can perform automated restore
#
# Steps:
# 1. Create empty MongoDB container with proper configuration
# 2. Initialize replica set
# 3. Install and start automation agent
# 4. Wait for agent to connect to Meta OM
# 5. User performs automated restore from Meta OM UI
# 6. Verify restoration

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="mongodb-ops-manager"
CONTAINER_HOSTNAME="de152bf62a02"  # CRITICAL: Must match original hostname for agent reconnection
VOLUME_NAME="primary-om-appdb"
EPHEMERAL_PORT="27018"
REPLICA_SET_NAME="appdb-rs"
MONGODB_IMAGE="mongodb/mongodb-enterprise-server:7.0-ubi8"
DOCKER_NETWORK="ops-manager_main"
# NOTE: Meta OM's automation config alias for appdb-rs_8 must use the container
# hostname (de152bf62a02) rather than an IP address. Docker reassigns IPs on
# container recreation, which causes the automation agent to fail with
# "unexpected mongo" error because the alias points to the wrong container.

echo "=== Disaster Recovery PoC - Phase 3: Prepare for Automated Restore ==="
echo ""
echo -e "${BLUE}This script prepares the infrastructure for Meta OM automated restore${NC}"
echo ""

# Step 1: Stop and remove existing container
echo "1. Cleaning up existing container"
echo "------------------------------"
docker stop $CONTAINER_NAME 2>/dev/null || true
docker rm $CONTAINER_NAME 2>/dev/null || true
echo -e "${GREEN}✓ Existing container removed${NC}"
echo ""

# Step 2: Create and clear volume
echo "2. Creating and clearing volume"
echo "------------------------------"
docker volume create $VOLUME_NAME 2>/dev/null || echo "Volume already exists"
echo "Clearing volume data..."
docker run --rm -v $VOLUME_NAME:/data alpine sh -c "rm -rf /data/db/* /data/db/.*" 2>/dev/null || true
echo -e "${GREEN}✓ Volume ready and empty${NC}"
echo ""

# Step 3: Create MongoDB container with original hostname
# Keep container alive with tail -f, don't start MongoDB manually
echo "3. Creating MongoDB container"
echo "------------------------------"
echo "Using hostname: $CONTAINER_HOSTNAME (matches original agent)"
docker run -d --name $CONTAINER_NAME --hostname $CONTAINER_HOSTNAME -p $EPHEMERAL_PORT:27017 \
  -v $VOLUME_NAME:/data/db \
  --network $DOCKER_NETWORK \
  --entrypoint /bin/bash \
  $MONGODB_IMAGE -c "tail -f /dev/null"

sleep 3
echo -e "${GREEN}✓ Container created: $CONTAINER_NAME (hostname: $CONTAINER_HOSTNAME)${NC}"
echo ""

# Step 4: Prepare directories and permissions for automation agent
echo "4. Preparing directories for automation"
echo "------------------------------"
# Create necessary directories
docker exec -u root $CONTAINER_NAME mkdir -p /var/log/mongodb
docker exec -u root $CONTAINER_NAME mkdir -p /var/lib/mongodb-mms-automation
docker exec -u root $CONTAINER_NAME mkdir -p /data/db

# Set ownership to mongod user
docker exec -u root $CONTAINER_NAME chown -R mongod:mongod /var/log/mongodb
docker exec -u root $CONTAINER_NAME chown -R mongod:mongod /var/lib/mongodb-mms-automation
docker exec -u root $CONTAINER_NAME chown -R mongod:mongod /data/db

echo -e "${GREEN}✓ Directories prepared${NC}"
echo ""

# Step 5: Install automation agent
echo "5. Installing automation agent"
echo "------------------------------"
cd /Users/prakhar.dhama/mongo-infra-docker
bash ./om-docker/meta-om-primary-appdb-agent-installation.sh
echo ""

# Step 6: Restart agent as mongod user (not root)
echo "6. Starting agent as mongod user"
echo "------------------------------"

# Stop the agent that was started by the installation script (running as root)
docker exec -u root $CONTAINER_NAME pkill -f automation-agent 2>/dev/null || true
sleep 2

# Fix permissions - everything should be owned by mongod
docker exec -u root $CONTAINER_NAME chown -R mongod:mongod /var/log/mongodb-mms-automation
docker exec -u root $CONTAINER_NAME chown -R mongod:mongod /opt/mongodb-mms-automation
docker exec -u root $CONTAINER_NAME chown mongod:mongod /etc/mongodb-mms/automation-agent.config
docker exec -u root $CONTAINER_NAME chown -R mongod:mongod /data/db
docker exec -u root $CONTAINER_NAME chown -R mongod:mongod /var/log/mongodb
docker exec -u root $CONTAINER_NAME chown -R mongod:mongod /var/lib/mongodb-mms-automation

# Fix lock file permissions (critical for agent to start as mongod user)
docker exec -u root $CONTAINER_NAME rm -f /tmp/mongodb-mms-automation.lock
docker exec -u root $CONTAINER_NAME touch /tmp/mongodb-mms-automation.lock
docker exec -u root $CONTAINER_NAME chown mongod:mongod /tmp/mongodb-mms-automation.lock

# Start agent as mongod user using docker exec -u (cleanest approach)
docker exec -u mongod -d $CONTAINER_NAME /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent -f /etc/mongodb-mms/automation-agent.config

sleep 5
echo -e "${GREEN}✓ Agent started as mongod user${NC}"
echo ""

# Step 7: Verify agent and MongoDB are running as mongod user
echo "7. Verifying agent status"
echo "------------------------------"
AGENT_PID=$(docker exec $CONTAINER_NAME pgrep -f automation-agent || echo "")
if [ -n "$AGENT_PID" ]; then
    AGENT_USER=$(docker exec $CONTAINER_NAME ps -o user= -p $AGENT_PID)
    echo -e "${GREEN}✓ Automation agent is running (PID: $AGENT_PID, User: $AGENT_USER)${NC}"

    # Wait a bit for agent to start MongoDB
    echo "Waiting for automation agent to start MongoDB..."
    sleep 10

    MONGOD_PID=$(docker exec $CONTAINER_NAME pgrep -f "mongod.*automation" || echo "")
    if [ -n "$MONGOD_PID" ]; then
        MONGOD_USER=$(docker exec $CONTAINER_NAME ps -o user= -p $MONGOD_PID | head -1)
        echo -e "${GREEN}✓ MongoDB is running (PID: $MONGOD_PID, User: $MONGOD_USER)${NC}"
    else
        echo -e "${YELLOW}⚠ MongoDB not started yet by automation agent${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Automation agent may not be running yet${NC}"
    echo "Check logs: docker exec $CONTAINER_NAME tail -20 /var/log/mongodb-mms-automation/automation-agent.log"
fi
echo ""

echo "=== Infrastructure Preparation Complete ==="
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}NEXT STEPS: Perform Automated Restore from Meta OM UI${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}1. Open Meta OM UI:${NC}"
echo "   http://localhost:8080"
echo ""
echo -e "${BLUE}2. Navigate to:${NC}"
echo "   Continuous Backup → appdb-rs → Restore History"
echo ""
echo -e "${BLUE}3. Click 'Restore' on the latest snapshot${NC}"
echo ""
echo -e "${BLUE}4. Choose restore method:${NC}"
echo "   • Automated Restore (recommended)"
echo "   • Select target: appdb-rs"
echo "   • Click 'Restore'"
echo ""
echo -e "${BLUE}5. Monitor restore progress in Meta OM UI${NC}"
echo ""
echo -e "${BLUE}6. After restore completes, run verification:${NC}"
echo "   ./om-disaster-recovery/4-verify-recovery.sh"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"


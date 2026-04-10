#!/bin/bash

# Disaster Recovery PoC - Phase 3: Prepare for Automated Restore
#
# This script prepares the infrastructure so Meta OM can perform an automated
# restore of appdb-rs. After running this script, trigger the restore from the
# Meta OM UI (or API), and the automation agent will handle everything:
# RS configuration, mongod startup, and data placement.
#
# Usage:
#   ./3-automated-restore-prepare.sh
#
# What it does:
#   1. Fetches the original container hostname from Meta OM's automation config
#   2. Creates an empty container with that hostname (so the agent reconnects)
#   3. Installs and starts the automation agent as the mongod user
#
# After running this script:
#   1. Go to Meta OM UI → Continuous Backup → appdb-rs → Restore
#   2. Choose Automated Restore → target: appdb-rs
#   3. Wait for restore to complete
#   4. Start Primary OM
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ WARNING: NEVER DIRECTLY EDIT Meta OM's appDB (automationcore, etc.)    │
# │                                                                         │
# │ Meta OM uses optimistic concurrency control (rcid + version) in its    │
# │ AutomationConfigDao. Direct DB edits desync the OM server's in-memory  │
# │ state, causing a permanent "Another session or user has already         │
# │ published changes" 409 error that survives OM restarts.                │
# │                                                                         │
# │ The ONLY safe ways to modify the automation config are:                │
# │   1. The Meta OM UI                                                    │
# │   2. The Meta OM REST API (PUT /api/public/v1.0/.../automationConfig)  │
# │                                                                         │
# │ See HELP-10875, HELP-12594, HELP-2060 for past incidents caused by     │
# │ direct DB edits.                                                        │
# └──────────────────────────────────────────────────────────────────────────┘

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="mongodb-ops-manager"
VOLUME_NAME="primary-om-appdb"
VOLUME_LOG_NAME="primary-om-appdb-log"
EPHEMERAL_PORT="27018"
REPLICA_SET_NAME="appdb-rs"
MONGODB_IMAGE="mongodb/mongodb-enterprise-server:7.0-ubi8"
DOCKER_NETWORK="ops-manager_main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Fetch the original hostname for appdb-rs from node1's cached automation config.
# node1 is in the same Meta OM project, so its config backup contains all processes.
fetch_appdb_hostname() {
    docker exec node1 cat /var/lib/mongodb-mms-automation/mms-cluster-config-backup.json 2>/dev/null | \
      python3 -c "
import sys, json
data = json.load(sys.stdin)
for proc in data.get('processes', []):
    rs = proc.get('args2_6',{}).get('replication',{}).get('replSetName','')
    if rs == '$REPLICA_SET_NAME':
        print(proc['hostname'])
        break
" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# Main: Prepare Infrastructure
#
# Creates the container with the correct hostname, installs the agent, and
# waits for you to trigger the restore from Meta OM UI.
#
# NOTE: This script does NOT modify Meta OM's automation config or any Meta OM
# database. The container hostname matches what Meta OM already knows, so the
# agent reconnects automatically — no alias changes needed.
# ══════════════════════════════════════════════════════════════════════════════

echo "=== Disaster Recovery PoC - Phase 3: Prepare for Automated Restore ==="
echo ""
echo -e "${BLUE}This script prepares the infrastructure for Meta OM automated restore.${NC}"
echo -e "${BLUE}After it completes, trigger the restore from Meta OM UI or API.${NC}"
echo ""

# Step 0: Fetch original hostname
echo "0. Fetching original hostname for $REPLICA_SET_NAME from Meta OM"
echo "------------------------------"
CONTAINER_HOSTNAME=$(fetch_appdb_hostname)
if [ -z "$CONTAINER_HOSTNAME" ]; then
    echo -e "${RED}✗ Could not determine original hostname for $REPLICA_SET_NAME${NC}"
    echo "  Checked: node1:/var/lib/mongodb-mms-automation/mms-cluster-config-backup.json"
    echo "  Is the node1 container running with a valid automation config backup?"
    exit 1
fi
echo -e "${GREEN}✓ Found hostname: $CONTAINER_HOSTNAME${NC}"
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
# Use tail -f to keep container alive — the automation agent will start mongod.
# The hostname MUST match what Meta OM has in its automation config so the agent
# reconnects to the existing server entry (no duplicate entries, backup resumes).
echo "3. Creating MongoDB container"
echo "------------------------------"
echo "Using hostname: $CONTAINER_HOSTNAME (matches original agent)"
docker run -d --name $CONTAINER_NAME --hostname $CONTAINER_HOSTNAME \
  -p $EPHEMERAL_PORT:27017 \
  -v $VOLUME_NAME:/data/db \
  -v $VOLUME_LOG_NAME:/var/log/mongodb \
  --network $DOCKER_NETWORK \
  --entrypoint /bin/bash \
  $MONGODB_IMAGE -c "tail -f /dev/null"

sleep 3
echo -e "${GREEN}✓ Container created: $CONTAINER_NAME (hostname: $CONTAINER_HOSTNAME)${NC}"
echo ""

# Step 4: Prepare directories and permissions
# /var/log/mongodb is required for mongod's systemLog.path — without it Meta OM
# shows "Invalid config: The required attribute logpath was not specified."
echo "4. Preparing directories for automation"
echo "------------------------------"
docker exec -u root $CONTAINER_NAME bash -c "
mkdir -p /var/log/mongodb /var/lib/mongodb-mms-automation /data/db /var/log/mongodb-mms-automation
chown -R mongod:mongod /var/log/mongodb /var/lib/mongodb-mms-automation /data/db /var/log/mongodb-mms-automation
"
echo -e "${GREEN}✓ Directories prepared${NC}"
echo ""

# Step 5: Install automation agent
echo "5. Installing automation agent"
echo "------------------------------"
cd "$REPO_DIR"
bash ./om-docker/meta-om-primary-appdb-agent-installation.sh
echo ""

# Step 6: Restart agent as mongod user (not root)
# The installation script starts the agent as root. The agent must run as the
# same UID as mongod (mongod user), otherwise it refuses to manage the process
# with: "Refusing to shut down mongod as it is running as a different UID than Automation"
echo "6. Starting agent as mongod user"
echo "------------------------------"
docker exec -u root $CONTAINER_NAME bash -c "
pkill -9 -f automation-agent 2>/dev/null || true
sleep 1
chown -R mongod:mongod /var/log/mongodb-mms-automation /opt/mongodb-mms-automation \
  /etc/mongodb-mms /data/db /var/log/mongodb /var/lib/mongodb-mms-automation 2>/dev/null || true
rm -f /tmp/mongodb-mms-automation.lock
"
docker exec -u mongod -d $CONTAINER_NAME /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent -f /etc/mongodb-mms/automation-agent.config
sleep 5
echo -e "${GREEN}✓ Agent started as mongod user${NC}"
echo ""

# Step 7: Verify agent
echo "7. Verifying agent status"
echo "------------------------------"
AGENT_PID=$(docker exec $CONTAINER_NAME pgrep -f automation-agent 2>/dev/null | head -1 || echo "")
if [ -n "$AGENT_PID" ]; then
    AGENT_USER=$(docker exec $CONTAINER_NAME ps -o user= -p $AGENT_PID 2>/dev/null | tr -d '[:space:]')
    echo -e "${GREEN}✓ Automation agent is running (PID: $AGENT_PID, User: $AGENT_USER)${NC}"
else
    echo -e "${YELLOW}⚠ Agent may not be running yet${NC}"
    echo "Check logs: docker exec $CONTAINER_NAME tail -20 /var/log/mongodb-mms-automation/automation-agent.log"
fi
echo ""

echo "=== Infrastructure Preparation Complete ==="
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}NEXT STEPS: Perform Restore from Meta OM${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}1. Open Meta OM UI:${NC} http://localhost:8080"
echo -e "${BLUE}2. Navigate to:${NC} Continuous Backup → appdb-rs → Restore"
echo -e "${BLUE}3. Choose:${NC} Automated Restore → target: appdb-rs"
echo -e "${BLUE}4. Wait for restore to complete${NC}"
echo -e "${BLUE}5. Start Primary OM:${NC} cd /Users/prakhar.dhama/ops-manager && bazel run --server_env=hosted //server:mms"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

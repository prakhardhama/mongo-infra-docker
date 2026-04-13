#!/bin/bash

# Deployment Reconciliation PoC — Phase 3: Prepare Infrastructure for Restore
#
# Precondition:
#   1. Phase 2 completed — appDB container and volume destroyed
#   2. Pre-disaster state saved at /tmp/reconciliation-poc/pre-disaster-latest.json
#   3. Meta OM is running with a snapshot of the OLD (pre-scale) config
#
# What this script does:
#   1. Reads pre-disaster state (container hostname, IP)
#   2. Recreates appDB container with original hostname + static IP
#   3. Installs automation agent (managed by Meta OM) as mongod user
#   4. Waits for agent to start mongod and initialize RS as PRIMARY
#
# After this script completes:
#   1. Trigger PITR restore from Meta OM UI (choose the OLD snapshot)
#   2. Start Primary OM and local agent
#   3. Run: ./4-verify-reconciliation.sh
#
# Usage:
#   ./3-restore-prepare.sh

echo "=== Deployment Reconciliation PoC — Phase 3: Prepare Infrastructure ==="
echo ""

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Configuration ───────────────────────────────────────────────────────────
CONTAINER_NAME="mongodb-ops-manager"
VOLUME_NAME="primary-om-appdb"
VOLUME_LOG_NAME="primary-om-appdb-log"
EPHEMERAL_PORT="27018"
MONGODB_IMAGE="mongodb/mongodb-enterprise-server:7.0-ubi8"
DOCKER_NETWORK="ops-manager_main"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

STATE_DIR="/tmp/reconciliation-poc"

# ─── Helpers ─────────────────────────────────────────────────────────────────
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
info() { echo -e "  ${BLUE}→${NC} $1"; }

run_mongosh() {
    local eval_str="$1"
    if docker exec "$CONTAINER_NAME" test -f /var/lib/mongodb-mms-automation/bin/mongosh 2>/dev/null; then
        docker exec "$CONTAINER_NAME" /var/lib/mongodb-mms-automation/bin/mongosh --quiet --eval "$eval_str" 2>/dev/null
    else
        docker exec "$CONTAINER_NAME" mongosh --quiet --eval "$eval_str" 2>/dev/null
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# 0. Load pre-disaster state
# ═════════════════════════════════════════════════════════════════════════════
echo "0. Loading pre-disaster state"
echo "-----------------------------"

PRE_DISASTER_FILE="${STATE_DIR}/pre-disaster-latest.json"
if [ ! -f "$PRE_DISASTER_FILE" ]; then
    fail "Pre-disaster state not found at $PRE_DISASTER_FILE"
    echo "  Run 2-simulate-disaster.sh first."
    exit 1
fi

CONTAINER_HOSTNAME=$(python3 -c "import json; print(json.load(open('$PRE_DISASTER_FILE'))['containerHostname'])" 2>/dev/null)
CONTAINER_IP=$(python3 -c "import json; print(json.load(open('$PRE_DISASTER_FILE'))['containerIP'])" 2>/dev/null)
PRE_DISASTER_VERSION=$(python3 -c "import json; print(json.load(open('$PRE_DISASTER_FILE'))['configVersion'])" 2>/dev/null)
PRE_DISASTER_PROCS=$(python3 -c "import json; print(json.load(open('$PRE_DISASTER_FILE'))['targetProcessCount'])" 2>/dev/null)

pass "Pre-disaster state loaded"
info "Container hostname: $CONTAINER_HOSTNAME"
info "Container IP: $CONTAINER_IP"
info "Pre-disaster config: version $PRE_DISASTER_VERSION, poRepSet: $PRE_DISASTER_PROCS nodes"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 1. Clean up any leftover container
# ═════════════════════════════════════════════════════════════════════════════
echo "1. Cleaning up existing container"
echo "----------------------------------"

docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true
pass "Existing container removed (if any)"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 2. Create volume and container with original hostname + static IP
# ═════════════════════════════════════════════════════════════════════════════
echo "2. Creating container with original hostname and static IP"
echo "----------------------------------------------------------"

docker volume create "$VOLUME_NAME" 2>/dev/null || true
docker volume create "$VOLUME_LOG_NAME" 2>/dev/null || true

# Clear any stale data in the volume
docker run --rm -v "$VOLUME_NAME":/data alpine sh -c "rm -rf /data/db/* /data/db/.*" 2>/dev/null || true

info "Hostname: $CONTAINER_HOSTNAME  IP: $CONTAINER_IP"

docker run -d --name "$CONTAINER_NAME" --hostname "$CONTAINER_HOSTNAME" \
  -p "$EPHEMERAL_PORT":27017 \
  -v "$VOLUME_NAME":/data/db \
  -v "$VOLUME_LOG_NAME":/var/log/mongodb \
  --network "$DOCKER_NETWORK" \
  --ip "$CONTAINER_IP" \
  --entrypoint /bin/bash \
  "$MONGODB_IMAGE" -c "tail -f /dev/null"

sleep 3

ACTUAL_IP=$(docker inspect "$CONTAINER_NAME" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
if [ "$ACTUAL_IP" = "$CONTAINER_IP" ]; then
    pass "Container created at $ACTUAL_IP (matches pre-disaster IP)"
else
    warn "Container IP is $ACTUAL_IP (expected $CONTAINER_IP) — agent alias may not match"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 3. Prepare directories
# ═════════════════════════════════════════════════════════════════════════════
echo "3. Preparing directories"
echo "------------------------"

docker exec -u root "$CONTAINER_NAME" bash -c "
mkdir -p /var/log/mongodb /var/lib/mongodb-mms-automation /data/db /var/log/mongodb-mms-automation
chown -R mongod:mongod /var/log/mongodb /var/lib/mongodb-mms-automation /data/db /var/log/mongodb-mms-automation
"
pass "Directories prepared"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 4. Install automation agent (Meta OM)
# ═════════════════════════════════════════════════════════════════════════════
echo "4. Installing automation agent"
echo "------------------------------"

cd "$REPO_DIR"
bash ./om-docker/meta-om-primary-appdb-agent-installation.sh

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 5. Restart agent as mongod user
# ═════════════════════════════════════════════════════════════════════════════
echo "5. Restarting agent as mongod user"
echo "-----------------------------------"

docker exec -u root "$CONTAINER_NAME" bash -c '
# Kill all agent processes (including zombies from the root-started installation)
kill -9 $(ps aux | grep "automation-agent\|mongodb-mms-aut" | grep -v grep | awk "{print $2}") 2>/dev/null || true
sleep 2
# Remove lock file and fix ALL permissions
rm -f /tmp/mongodb-mms-automation.lock
# chmod the verbose log to world-writable in case chown fails on active files
chmod 777 /var/log/mongodb-mms-automation/automation-agent-verbose.log 2>/dev/null || true
chown -R mongod:mongod /var/log/mongodb-mms-automation /opt/mongodb-mms-automation \
  /etc/mongodb-mms /data/db /var/log/mongodb /var/lib/mongodb-mms-automation 2>/dev/null || true
'
docker exec -u mongod -d "$CONTAINER_NAME" /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent \
  -f /etc/mongodb-mms/automation-agent.config
sleep 5

AGENT_PID=$(docker exec "$CONTAINER_NAME" pgrep -f automation-agent 2>/dev/null | head -1 || echo "")
if [ -n "$AGENT_PID" ]; then
    AGENT_USER=$(docker exec "$CONTAINER_NAME" ps -o user= -p "$AGENT_PID" 2>/dev/null | tr -d '[:space:]')
    pass "Agent running as $AGENT_USER (PID: $AGENT_PID)"
else
    warn "Agent may not be running — check logs"
    info "docker exec $CONTAINER_NAME tail -20 /var/log/mongodb-mms-automation/automation-agent.log"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 6. Wait for agent to initialize appDB (mongod + RS)
# ═════════════════════════════════════════════════════════════════════════════
echo "6. Waiting for agent to start mongod and initialize RS"
echo "-------------------------------------------------------"

MAX_WAIT=300
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    RS_STATE=$(run_mongosh "
    try { var s = rs.status(); print(s.members[0].stateStr); }
    catch(e) { print('NOT_READY'); }
    " | tail -1 2>/dev/null || echo "NOT_READY")

    if [ "$RS_STATE" = "PRIMARY" ]; then
        pass "appDB RS is PRIMARY (took ${WAITED}s)"
        break
    fi

    if [ $((WAITED % 30)) -eq 0 ] && [ $WAITED -gt 0 ]; then
        PROGRESS=$(docker exec "$CONTAINER_NAME" tail -3 /var/log/mongodb-mms-automation/automation-agent-verbose.log 2>/dev/null \
          | grep -oE "Downloaded [0-9]+MB|Running step.*|Starting to download" | tail -1)
        info "Still waiting... (${WAITED}s) ${PROGRESS:-RS state: $RS_STATE}"
    fi

    sleep 5
    WAITED=$((WAITED + 5))
done

if [ "$RS_STATE" != "PRIMARY" ]; then
    fail "appDB RS did not become PRIMARY after ${MAX_WAIT}s"
    info "Agent may still be downloading MongoDB. Check:"
    info "  docker exec $CONTAINER_NAME tail -20 /var/log/mongodb-mms-automation/automation-agent-verbose.log"
    echo ""
    echo "Once appDB is PRIMARY, re-run this script or continue manually."
    exit 1
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# Done — print next steps
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  INFRASTRUCTURE READY — Trigger restore now${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Trigger PITR restore from Meta OM UI:"
echo "     http://localhost:8080 → Continuous Backup → appdb-rs → Restore"
echo "     Choose a snapshot with poRepSet: 3 nodes (config version ≤ 9)"
echo ""
echo "  2. Wait for restore to complete in Meta OM UI"
echo ""
echo "  3. Start Primary OM (in a separate terminal):"
echo "     cd ~/ops-manager"
echo "     bazel run --server_env=hosted //server:mms -- \\"
echo "       --jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled"
echo ""
echo "  4. Start local agent (in a separate terminal):"
echo "     cd ~/mms-automation/go_planner/src/com.tengen/cm/main"
echo "     go run cm.go --config=local.config"
echo ""
echo "  5. Run: ./4-verify-reconciliation.sh"
echo ""

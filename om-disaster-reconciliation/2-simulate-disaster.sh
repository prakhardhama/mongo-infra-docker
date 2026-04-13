#!/bin/bash

# Deployment Reconciliation PoC — Phase 2: Simulate Disaster
#
# Precondition:
#   1. Phase 1 (1-verify-setup.sh) passed — baseline saved
#   2. poRepSet was SCALED (e.g. 3 → 5 nodes) via Primary OM UI
#   3. Agents converged on the new config (check Primary OM UI)
#   4. Meta OM snapshot still has the OLD (pre-scale) config
#
# What this script does:
#   1. Records the CURRENT (post-scale) state as pre-disaster snapshot
#      — config version, poRepSet node count, hostnames
#   2. Compares with Phase 1 baseline to confirm scaling happened
#   3. Stops Primary OM (bazel process)
#   4. Destroys appDB container and volume (catastrophic failure)
#   5. Verifies complete data loss
#
# After this script:
#   → Run 3-restore-and-reconcile.sh
#
# Usage:
#   ./2-simulate-disaster.sh
#   TARGET_RS=myRS ./2-simulate-disaster.sh

echo "=== Deployment Reconciliation PoC — Phase 2: Simulate Disaster ==="
echo ""

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Configuration ───────────────────────────────────────────────────────────
APPDB_CONTAINER="mongodb-ops-manager"
VOLUME_NAME="primary-om-appdb"
VOLUME_LOG_NAME="primary-om-appdb-log"
TARGET_RS="${TARGET_RS:-poRepSet}"

STATE_DIR="/tmp/reconciliation-poc"
mkdir -p "$STATE_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PRE_DISASTER_FILE="${STATE_DIR}/pre-disaster-${TIMESTAMP}.json"

# ─── Helpers ─────────────────────────────────────────────────────────────────
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
info() { echo -e "  ${BLUE}→${NC} $1"; }

run_mongosh() {
    local eval_str="$1"
    if docker exec "$APPDB_CONTAINER" test -f /var/lib/mongodb-mms-automation/bin/mongosh 2>/dev/null; then
        docker exec "$APPDB_CONTAINER" /var/lib/mongodb-mms-automation/bin/mongosh --quiet --eval "$eval_str" 2>/dev/null
    else
        docker exec "$APPDB_CONTAINER" mongosh --quiet --eval "$eval_str" 2>/dev/null
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# 0. Pre-flight checks
# ═════════════════════════════════════════════════════════════════════════════
echo "0. Pre-flight checks"
echo "--------------------"

# appDB must be reachable
if ! run_mongosh "db.adminCommand({ping: 1})" | grep -q "ok" 2>/dev/null; then
    fail "appDB is not reachable — cannot record pre-disaster state"
    exit 1
fi
pass "appDB accessible"

# Check baseline exists from Phase 1
BASELINE_FILE="${STATE_DIR}/baseline-latest.json"
if [ -f "$BASELINE_FILE" ]; then
    BASELINE_VERSION=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['configVersion'])" 2>/dev/null || echo "?")
    BASELINE_PROCS=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['targetProcessCount'])" 2>/dev/null || echo "?")
    pass "Phase 1 baseline found (version $BASELINE_VERSION, $TARGET_RS: $BASELINE_PROCS nodes)"
else
    warn "No Phase 1 baseline found — comparison will be skipped"
    BASELINE_VERSION="?"
    BASELINE_PROCS="?"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 1. Record pre-disaster state (post-scale topology)
# ═════════════════════════════════════════════════════════════════════════════
echo "1. Recording pre-disaster state"
echo "-------------------------------"

CONFIG_JSON=$(run_mongosh "
var doc = db.getSiblingDB('automationcore').getCollection('config.automation').findOne({});
if (!doc) { print(JSON.stringify({error:'no config'})); quit(); }

var ver = doc.version;
if (typeof ver === 'object' && ver !== null) ver = Number(ver);

var cluster = doc.cluster || {};
var allProcs = cluster.processes || doc.processes || [];
var allRsSets = cluster.replicaSets || doc.replicaSets || [];

var procs = allProcs.filter(function(p) {
    return p.args2_6 && p.args2_6.replication &&
           p.args2_6.replication.replSetName === '$TARGET_RS';
});
var rsCfg = allRsSets.filter(function(r) { return r._id === '$TARGET_RS'; });
var members = rsCfg.length > 0 ? rsCfg[0].members.length : 0;

var allRsNames = [];
allProcs.forEach(function(p) {
    var rs = (p.args2_6 && p.args2_6.replication) ? p.args2_6.replication.replSetName : null;
    if (rs && allRsNames.indexOf(rs) === -1) allRsNames.push(rs);
});

print(JSON.stringify({
    configVersion: ver || 0,
    groupId: doc.groupId || '',
    targetProcesses: procs.length,
    targetMembers: members,
    targetHostnames: procs.map(function(p){ return p.hostname + ':' + p.args2_6.net.port; }),
    allReplicaSets: allRsNames,
    totalProcesses: allProcs.length
}));
" | tail -1 || echo '{"error":"query failed"}')

CONFIG_VERSION=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('configVersion',0))" 2>/dev/null || echo "0")
GROUP_ID=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('groupId',''))" 2>/dev/null || echo "")
TARGET_PROCS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('targetProcesses',0))" 2>/dev/null || echo "0")
TARGET_MEMBERS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('targetMembers',0))" 2>/dev/null || echo "0")
TARGET_HOSTS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('targetHostnames',[])))" 2>/dev/null || echo "")
TOTAL_PROCS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalProcesses',0))" 2>/dev/null || echo "0")

info "Config version: $CONFIG_VERSION"
info "Group ID: $GROUP_ID"
info "$TARGET_RS: $TARGET_PROCS processes, $TARGET_MEMBERS members"
info "Hosts: $TARGET_HOSTS"
info "Total processes: $TOTAL_PROCS"

# Record the group restoration mode state
RESTORATION_MODE=$(run_mongosh "
var grp = db.getSiblingDB('mmsdbconfig').getCollection('config.customers').findOne(
    {_id: ObjectId('$GROUP_ID')}, {restorationMode:1}
);
print(grp ? grp.restorationMode : 'N/A');
" | tail -1 2>/dev/null || echo "N/A")
info "Restoration mode: $RESTORATION_MODE"

# Record the appDB container hostname and IP (needed for Phase 3)
CONTAINER_HOSTNAME=$(docker exec "$APPDB_CONTAINER" hostname 2>/dev/null || echo "unknown")
CONTAINER_IP=$(docker inspect "$APPDB_CONTAINER" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "unknown")
info "Container hostname: $CONTAINER_HOSTNAME"
info "Container IP: $CONTAINER_IP"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 2. Compare with Phase 1 baseline
# ═════════════════════════════════════════════════════════════════════════════
echo "2. Compare with Phase 1 baseline"
echo "---------------------------------"

if [ "$BASELINE_VERSION" != "?" ]; then
    if [ "$CONFIG_VERSION" -gt "$BASELINE_VERSION" ] 2>/dev/null; then
        pass "Config version increased: $BASELINE_VERSION → $CONFIG_VERSION"
    elif [ "$CONFIG_VERSION" -eq "$BASELINE_VERSION" ] 2>/dev/null; then
        warn "Config version unchanged ($CONFIG_VERSION) — was $TARGET_RS actually scaled?"
    else
        fail "Config version decreased: $BASELINE_VERSION → $CONFIG_VERSION (unexpected)"
    fi

    if [ "$TARGET_PROCS" -gt "$BASELINE_PROCS" ] 2>/dev/null; then
        pass "$TARGET_RS scaled: $BASELINE_PROCS → $TARGET_PROCS nodes"
    elif [ "$TARGET_PROCS" -eq "$BASELINE_PROCS" ] 2>/dev/null; then
        warn "$TARGET_RS node count unchanged ($TARGET_PROCS) — scale it before proceeding"
    else
        warn "$TARGET_RS node count decreased: $BASELINE_PROCS → $TARGET_PROCS"
    fi
else
    warn "No baseline to compare — skipping"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 3. Save pre-disaster state
# ═════════════════════════════════════════════════════════════════════════════
echo "3. Saving pre-disaster state"
echo "----------------------------"

python3 << PYEOF
import json

def safe_int(val, default=0):
    try:
        return int(val)
    except (ValueError, TypeError):
        return default

pre_disaster = {
    "timestamp": "${TIMESTAMP}",
    "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "configVersion": safe_int("${CONFIG_VERSION}"),
    "groupId": "${GROUP_ID}",
    "targetReplicaSet": "${TARGET_RS}",
    "targetProcessCount": safe_int("${TARGET_PROCS}"),
    "targetMemberCount": safe_int("${TARGET_MEMBERS}"),
    "targetHostnames": [h.strip() for h in "${TARGET_HOSTS}".split(",") if h.strip()],
    "totalProcesses": safe_int("${TOTAL_PROCS}"),
    "restorationMode": "${RESTORATION_MODE}",
    "containerHostname": "${CONTAINER_HOSTNAME}",
    "containerIP": "${CONTAINER_IP}",
}
with open("${PRE_DISASTER_FILE}", "w") as f:
    json.dump(pre_disaster, f, indent=2)
print(json.dumps(pre_disaster, indent=2))
PYEOF

ln -sf "$PRE_DISASTER_FILE" "${STATE_DIR}/pre-disaster-latest.json"
echo ""
info "Saved to: $PRE_DISASTER_FILE"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 4. Confirm destruction
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
echo -e "${RED}  WARNING: This will DESTROY the appDB container and volume!   ${NC}"
echo -e "${RED}                                                                ${NC}"
echo -e "${RED}  Container: $APPDB_CONTAINER                                   ${NC}"
echo -e "${RED}  Volumes:   $VOLUME_NAME, $VOLUME_LOG_NAME                     ${NC}"
echo -e "${RED}  All appDB data will be permanently lost.                      ${NC}"
echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Pre-disaster state saved. After destruction, recovery is only"
echo "possible from Meta OM backup (which has the OLD, pre-scale config)."
echo ""
read -p "Type 'DESTROY' to proceed: " confirm

if [ "$confirm" != "DESTROY" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 5. Stop Primary OM
# ═════════════════════════════════════════════════════════════════════════════
echo "5. Stopping Primary OM"
echo "----------------------"

PRIMARY_OM_PIDS=$(pgrep -f "bazel.*server:mms|com.xgen.svc.core.ServerMain" 2>/dev/null || echo "")
if [ -n "$PRIMARY_OM_PIDS" ]; then
    echo "$PRIMARY_OM_PIDS" | xargs kill 2>/dev/null || true
    sleep 3
    pass "Primary OM stopped (PIDs: $(echo $PRIMARY_OM_PIDS | tr '\n' ' '))"
else
    pass "Primary OM is not running"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 6. Stop local automation agent
# ═════════════════════════════════════════════════════════════════════════════
echo "6. Stopping local automation agent"
echo "-----------------------------------"

LOCAL_AGENT_PIDS=$(pgrep -f "cm\.go|cm --config" 2>/dev/null || echo "")
if [ -n "$LOCAL_AGENT_PIDS" ]; then
    echo "$LOCAL_AGENT_PIDS" | xargs kill 2>/dev/null || true
    sleep 2
    pass "Local agent stopped (PIDs: $(echo $LOCAL_AGENT_PIDS | tr '\n' ' '))"
else
    pass "Local agent is not running"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 7. Destroy appDB container and volume
# ═════════════════════════════════════════════════════════════════════════════
echo "7. Destroying appDB"
echo "--------------------"

echo "Stopping container..."
docker stop "$APPDB_CONTAINER" 2>/dev/null || true
echo "Removing container..."
docker rm "$APPDB_CONTAINER" 2>/dev/null || true
echo "Destroying data volume..."
docker volume rm "$VOLUME_NAME" 2>/dev/null || true
echo "Destroying log volume..."
docker volume rm "$VOLUME_LOG_NAME" 2>/dev/null || true

pass "Container and volumes destroyed"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 8. Verify complete data loss
# ═════════════════════════════════════════════════════════════════════════════
echo "8. Verifying data loss"
echo "----------------------"

CONTAINER_EXISTS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -cx "${APPDB_CONTAINER}" || true)
VOLUME_EXISTS=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -cx "${VOLUME_NAME}" || true)

if [ "${CONTAINER_EXISTS:-0}" -eq 0 ] && [ "${VOLUME_EXISTS:-0}" -eq 0 ]; then
    pass "Complete data loss confirmed — no container, no volume"
else
    fail "Cleanup incomplete: container=$CONTAINER_EXISTS volume=$VOLUME_EXISTS"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  DISASTER SIMULATED${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  What was destroyed:"
echo "    ✗ Container: $APPDB_CONTAINER"
echo "    ✗ Volume:    $VOLUME_NAME"
echo "    ✗ Volume:    $VOLUME_LOG_NAME"
echo "    ✗ Primary OM: stopped"
echo "    ✗ Local agent: stopped"
echo ""
echo "  Pre-disaster state (what reconciliation must recover TO):"
echo "    $TARGET_RS: $TARGET_PROCS nodes (config version $CONFIG_VERSION)"
echo "    Hosts: $TARGET_HOSTS"
echo ""
echo "  Meta OM snapshot has (what restore will give us):"
echo "    $TARGET_RS: $BASELINE_PROCS nodes (config version $BASELINE_VERSION)"
echo ""
echo "  State files:"
echo "    Baseline (Phase 1): $BASELINE_FILE"
echo "    Pre-disaster:       $PRE_DISASTER_FILE"
echo ""
echo -e "${YELLOW}  After reconciliation, $TARGET_RS must show $TARGET_PROCS nodes${NC}"
echo -e "${YELLOW}  (not $BASELINE_PROCS from the stale snapshot).${NC}"
echo ""
echo "  Next: ./3-restore-and-reconcile.sh"
echo ""

#!/bin/bash

# Deployment Reconciliation PoC — Phase 4: Verify Restore & Monitor Reconciliation
#
# Precondition:
#   1. Phase 3 completed — appDB container running with RS PRIMARY
#   2. PITR restore triggered from Meta OM UI (old snapshot with 3 nodes)
#   3. Primary OM running with --jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled
#   4. Local agent running with omBackupFeatureFlag=true in local.config
#
# What this script does:
#   1. Verifies Primary OM and local agent are running with correct flags
#   2. Verifies restored appDB has stale config (version < pre-disaster)
#   3. Monitors reconciliation (restorationMode flip, config version change)
#   4. Verifies final state matches pre-disaster topology
#
# Usage:
#   ./4-verify-reconciliation.sh

echo "=== Deployment Reconciliation PoC — Phase 4: Verify & Monitor Reconciliation ==="
echo ""

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Configuration ───────────────────────────────────────────────────────────
APPDB_CONTAINER="mongodb-ops-manager"
TARGET_RS="${TARGET_RS:-poRepSet}"
STATE_DIR="/tmp/reconciliation-poc"

# ─── Helpers ─────────────────────────────────────────────────────────────────
check_passed=0
check_failed=0

pass() { echo -e "${GREEN}✓${NC} $1"; ((check_passed++)); }
fail() { echo -e "${RED}✗${NC} $1"; ((check_failed++)); }
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
# 0. Load state files
# ═════════════════════════════════════════════════════════════════════════════
echo "0. Loading state files"
echo "----------------------"

PRE_DISASTER_FILE="${STATE_DIR}/pre-disaster-latest.json"
BASELINE_FILE="${STATE_DIR}/baseline-latest.json"

if [ ! -f "$PRE_DISASTER_FILE" ]; then
    fail "Pre-disaster state not found at $PRE_DISASTER_FILE"
    exit 1
fi

PRE_DISASTER_VERSION=$(python3 -c "import json; print(json.load(open('$PRE_DISASTER_FILE'))['configVersion'])" 2>/dev/null)
PRE_DISASTER_PROCS=$(python3 -c "import json; print(json.load(open('$PRE_DISASTER_FILE'))['targetProcessCount'])" 2>/dev/null)
PRE_DISASTER_HOSTS=$(python3 -c "import json; print(', '.join(json.load(open('$PRE_DISASTER_FILE'))['targetHostnames']))" 2>/dev/null)
GROUP_ID=$(python3 -c "import json; print(json.load(open('$PRE_DISASTER_FILE'))['groupId'])" 2>/dev/null)

BASELINE_VERSION="?"
BASELINE_PROCS="?"
if [ -f "$BASELINE_FILE" ]; then
    BASELINE_VERSION=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['configVersion'])" 2>/dev/null || echo "?")
    BASELINE_PROCS=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['targetProcessCount'])" 2>/dev/null || echo "?")
fi

info "Pre-disaster: version $PRE_DISASTER_VERSION, $TARGET_RS: $PRE_DISASTER_PROCS nodes"
info "Baseline (snapshot era): version $BASELINE_VERSION, $TARGET_RS: $BASELINE_PROCS nodes"
info "Group ID: $GROUP_ID"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 1. Pre-flight: verify OM and agent are running
# ═════════════════════════════════════════════════════════════════════════════
echo "1. Pre-flight checks"
echo "--------------------"

# Primary OM running with flag
OM_FLAG=$(ps aux | grep -o '\-Dmms.featureFlag.automation.restorationMode=[^ ]*' 2>/dev/null | head -1 || echo "")
if echo "$OM_FLAG" | grep -q '=enabled'; then
    pass "Primary OM running with restorationMode=enabled"
else
    fail "Primary OM not running with restorationMode flag"
    echo "  Start: cd ~/ops-manager && bazel run --server_env=hosted //server:mms -- \\"
    echo "    --jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled"
    exit 1
fi

# Primary OM accessible
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8081 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|302|303)$ ]]; then
    pass "Primary OM accessible (http://localhost:8081)"
else
    fail "Primary OM not accessible (HTTP $HTTP_CODE)"
    exit 1
fi

# Local agent running with flag
LOCAL_CONFIG="/Users/prakhar.dhama/mms-automation/go_planner/src/com.tengen/cm/main/local.config"
AGENT_RUNNING=$(ps aux 2>/dev/null | grep -E "cm\.go|cm --config" | grep -v grep | head -1 || echo "")
if [ -n "$AGENT_RUNNING" ]; then
    if grep -q "omBackupFeatureFlag=true" "$LOCAL_CONFIG" 2>/dev/null; then
        pass "Local agent running with omBackupFeatureFlag=true"
    else
        fail "Local agent running but omBackupFeatureFlag not set in local.config"
        exit 1
    fi
else
    fail "Local agent not running"
    echo "  Start: cd ~/mms-automation/go_planner/src/com.tengen/cm/main && go run cm.go --config=local.config"
    exit 1
fi

# appDB accessible
if run_mongosh "db.adminCommand({ping: 1})" | grep -q "ok" 2>/dev/null; then
    pass "appDB accessible"
else
    fail "appDB not accessible"
    exit 1
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 2. Verify restored state is stale
# ═════════════════════════════════════════════════════════════════════════════
echo "2. Checking restored appDB state"
echo "---------------------------------"

RESTORED_JSON=$(run_mongosh "
var doc = db.getSiblingDB('automationcore').getCollection('config.automation').findOne({});
if (!doc) { print(JSON.stringify({configVersion: 0, targetProcesses: 0})); quit(); }
var ver = doc.version;
if (typeof ver === 'object' && ver !== null) ver = Number(ver);
var cluster = doc.cluster || {};
var allProcs = cluster.processes || doc.processes || [];
var procs = allProcs.filter(function(p) {
    return p.args2_6 && p.args2_6.replication &&
           p.args2_6.replication.replSetName === '$TARGET_RS';
});
print(JSON.stringify({configVersion: ver || 0, targetProcesses: procs.length}));
" | tail -1 || echo '{"configVersion":0,"targetProcesses":0}')

RESTORED_VERSION=$(echo "$RESTORED_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('configVersion',0))" 2>/dev/null || echo "0")
RESTORED_PROCS=$(echo "$RESTORED_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('targetProcesses',0))" 2>/dev/null || echo "0")

info "Restored config version: $RESTORED_VERSION (pre-disaster: $PRE_DISASTER_VERSION)"
info "Restored $TARGET_RS processes: $RESTORED_PROCS (pre-disaster: $PRE_DISASTER_PROCS)"

if [ "$RESTORED_VERSION" -lt "$PRE_DISASTER_VERSION" ] 2>/dev/null; then
    pass "Restored config is STALE (version $RESTORED_VERSION < $PRE_DISASTER_VERSION)"
else
    warn "Config version $RESTORED_VERSION is not less than $PRE_DISASTER_VERSION — reconciliation may already be done or snapshot is too recent"
fi

if [ "$RESTORED_PROCS" -lt "$PRE_DISASTER_PROCS" ] 2>/dev/null; then
    pass "$TARGET_RS has fewer nodes ($RESTORED_PROCS < $PRE_DISASTER_PROCS) — reconciliation needed"
else
    warn "$TARGET_RS already has $RESTORED_PROCS nodes (expected < $PRE_DISASTER_PROCS)"
fi

# Save restored state
RESTORED_FILE="${STATE_DIR}/restored-$(date +%Y%m%d_%H%M%S).json"
python3 << PYEOF
import json
restored = {
    "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "configVersion": int("${RESTORED_VERSION}") if "${RESTORED_VERSION}".isdigit() else 0,
    "targetProcesses": int("${RESTORED_PROCS}") if "${RESTORED_PROCS}".isdigit() else 0,
}
with open("${RESTORED_FILE}", "w") as f:
    json.dump(restored, f, indent=2)
PYEOF
ln -sf "$RESTORED_FILE" "${STATE_DIR}/restored-latest.json"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 3. Monitor reconciliation
# ═════════════════════════════════════════════════════════════════════════════
echo "3. Monitoring reconciliation"
echo "----------------------------"
echo ""
echo "  Agent polls OM with cv=$PRE_DISASTER_VERSION (its local config version)."
echo "  OM detects cv > restored version ($RESTORED_VERSION) → enters restoration mode."
echo "  Reconciliation collects canonical config from agent → persists to AppDB → exits."
echo ""
echo "  Watching restorationMode flag and config version..."
echo ""

MAX_WAIT=300
WAITED=0
RECONCILIATION_STARTED=false
RECONCILIATION_COMPLETE=false

while [ $WAITED -lt $MAX_WAIT ]; do
    # Single mongosh call to get all state at once
    STATE=$(run_mongosh "
    var grp = db.getSiblingDB('mmsdbconfig').getCollection('config.customers').findOne(
        {_id: ObjectId('$GROUP_ID')}, {restorationMode:1});
    var doc = db.getSiblingDB('automationcore').getCollection('config.automation').findOne({});
    var ver = doc ? doc.version : 0;
    if (typeof ver === 'object' && ver !== null) ver = Number(ver);
    var cluster = doc ? (doc.cluster || {}) : {};
    var allProcs = cluster.processes || (doc ? doc.processes : []) || [];
    var procs = allProcs.filter(function(p) {
        return p.args2_6 && p.args2_6.replication &&
               p.args2_6.replication.replSetName === '$TARGET_RS';
    });
    var rm = grp ? grp.restorationMode : 'N/A';
    print(rm + '|' + ver + '|' + procs.length);
    " | tail -1 2>/dev/null || echo "N/A|0|0")

    CURRENT_RESTORATION=$(echo "$STATE" | cut -d'|' -f1)
    CURRENT_VERSION=$(echo "$STATE" | cut -d'|' -f2)
    CURRENT_PROCS=$(echo "$STATE" | cut -d'|' -f3)

    # Detect transitions
    if [ "$CURRENT_RESTORATION" = "true" ] && [ "$RECONCILIATION_STARTED" = false ]; then
        RECONCILIATION_STARTED=true
        echo -e "  [${WAITED}s] ${GREEN}✓ RESTORATION MODE ENTERED${NC}"
        echo "          restorationMode=true — OM detected version mismatch"
    fi

    if [ "$RECONCILIATION_STARTED" = true ] && [ "$CURRENT_RESTORATION" = "false" ]; then
        RECONCILIATION_COMPLETE=true
        echo -e "  [${WAITED}s] ${GREEN}✓ RESTORATION MODE EXITED${NC}"
        echo "          restorationMode=false — reconciliation completed!"
        echo "          Config version: $CURRENT_VERSION  $TARGET_RS: $CURRENT_PROCS nodes"
        break
    fi

    # Also detect if reconciliation completed without us seeing the true→false transition
    # (e.g. it happened between polls)
    if [ "$RECONCILIATION_STARTED" = false ] && [ "$CURRENT_RESTORATION" = "false" ] \
       && [ "${CURRENT_VERSION:-0}" -gt "${RESTORED_VERSION:-0}" ] 2>/dev/null \
       && [ "${CURRENT_PROCS:-0}" -ge "${PRE_DISASTER_PROCS:-0}" ] 2>/dev/null; then
        RECONCILIATION_COMPLETE=true
        echo -e "  [${WAITED}s] ${GREEN}✓ RECONCILIATION ALREADY COMPLETE${NC}"
        echo "          Config version: $CURRENT_VERSION  $TARGET_RS: $CURRENT_PROCS nodes"
        break
    fi

    # Progress update every 10 seconds
    if [ $((WAITED % 10)) -eq 0 ]; then
        echo "  [${WAITED}s] restorationMode=$CURRENT_RESTORATION  version=$CURRENT_VERSION  ${TARGET_RS}=$CURRENT_PROCS nodes"
    fi

    sleep 5
    WAITED=$((WAITED + 5))
done

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 4. Final verification
# ═════════════════════════════════════════════════════════════════════════════
echo "4. Final verification"
echo "---------------------"

# Wait for version-convergence loop to stabilize. After reconciliation, the republished
# version may be less than the agent's version, causing another cycle. This typically
# resolves in 2-3 cycles (~60-90 seconds).
info "Waiting for version convergence to stabilize..."
STABILIZE_WAIT=120
STABILIZE_ELAPSED=0
while [ $STABILIZE_ELAPSED -lt $STABILIZE_WAIT ]; do
    S_RM=$(run_mongosh "
    var grp = db.getSiblingDB('mmsdbconfig').getCollection('config.customers').findOne(
        {_id: ObjectId('$GROUP_ID')}, {restorationMode:1});
    print(grp ? grp.restorationMode : 'N/A');
    " | tail -1 2>/dev/null || echo "N/A")
    if [ "$S_RM" = "false" ]; then
        # Stable — wait one more poll cycle to confirm it stays false
        sleep 15
        S_RM2=$(run_mongosh "
        var grp = db.getSiblingDB('mmsdbconfig').getCollection('config.customers').findOne(
            {_id: ObjectId('$GROUP_ID')}, {restorationMode:1});
        print(grp ? grp.restorationMode : 'N/A');
        " | tail -1 2>/dev/null || echo "N/A")
        if [ "$S_RM2" = "false" ]; then
            info "restorationMode stable at false"
            break
        fi
    fi
    sleep 10
    STABILIZE_ELAPSED=$((STABILIZE_ELAPSED + 10))
done

FINAL_STATE=$(run_mongosh "
var grp = db.getSiblingDB('mmsdbconfig').getCollection('config.customers').findOne(
    {_id: ObjectId('$GROUP_ID')}, {restorationMode:1});
var doc = db.getSiblingDB('automationcore').getCollection('config.automation').findOne({});
var ver = doc ? doc.version : 0;
if (typeof ver === 'object' && ver !== null) ver = Number(ver);
var cluster = doc ? (doc.cluster || {}) : {};
var allProcs = cluster.processes || (doc ? doc.processes : []) || [];
var procs = allProcs.filter(function(p) {
    return p.args2_6 && p.args2_6.replication &&
           p.args2_6.replication.replSetName === '$TARGET_RS';
});
var hosts = procs.map(function(p){ return p.hostname + ':' + p.args2_6.net.port; });
var rm = grp ? grp.restorationMode : 'N/A';
print(rm + '|' + ver + '|' + procs.length + '|' + hosts.join(','));
" | tail -1 2>/dev/null || echo "N/A|0|0|")

FINAL_RESTORATION=$(echo "$FINAL_STATE" | cut -d'|' -f1)
FINAL_VERSION=$(echo "$FINAL_STATE" | cut -d'|' -f2)
FINAL_PROCS=$(echo "$FINAL_STATE" | cut -d'|' -f3)
FINAL_HOSTS=$(echo "$FINAL_STATE" | cut -d'|' -f4)

# Check restoration mode exited
if [ "$FINAL_RESTORATION" = "false" ]; then
    pass "restorationMode is false (reconciliation exited cleanly)"
else
    fail "restorationMode is still $FINAL_RESTORATION"
fi

# Check process count matches pre-disaster
if [ "$FINAL_PROCS" -eq "$PRE_DISASTER_PROCS" ] 2>/dev/null; then
    pass "$TARGET_RS has $FINAL_PROCS nodes (matches pre-disaster: $PRE_DISASTER_PROCS)"
elif [ "$FINAL_PROCS" -gt "$RESTORED_PROCS" ] 2>/dev/null; then
    warn "$TARGET_RS has $FINAL_PROCS nodes (restored had $RESTORED_PROCS, pre-disaster was $PRE_DISASTER_PROCS)"
else
    fail "$TARGET_RS has $FINAL_PROCS nodes (expected $PRE_DISASTER_PROCS)"
fi

# Check config version increased from restored
if [ "$FINAL_VERSION" -gt "$RESTORED_VERSION" ] 2>/dev/null; then
    pass "Config version increased: $RESTORED_VERSION → $FINAL_VERSION"
else
    fail "Config version did not increase: still $FINAL_VERSION (restored was $RESTORED_VERSION)"
fi

# Check hosts
info "Hosts: $FINAL_HOSTS"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo ""

if [ "$RECONCILIATION_COMPLETE" = true ] && [ $check_failed -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  DEPLOYMENT RECONCILIATION POC SUCCESSFUL!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Summary:"
    echo "    ✓ appDB destroyed and restored from stale snapshot"
    echo "    ✓ Restored state: version $RESTORED_VERSION, $TARGET_RS: $RESTORED_PROCS nodes"
    echo "    ✓ Restoration mode entered (version mismatch detected)"
    echo "    ✓ Reconciliation collected canonical config from agent"
    echo "    ✓ Config persisted to AppDB and restoration mode exited"
    echo "    ✓ Final state: version $FINAL_VERSION, $TARGET_RS: $FINAL_PROCS nodes"
    echo "    ✓ Hosts: $FINAL_HOSTS"
    echo ""
    echo "  Checks passed: $check_passed"
    echo "  Checks failed: $check_failed"
    echo ""
elif [ "$RECONCILIATION_STARTED" = true ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  RECONCILIATION IN PROGRESS (timed out after ${MAX_WAIT}s)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Restoration mode entered but reconciliation has not completed."
    echo "  Re-run this script to continue monitoring."
    echo ""
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  RECONCILIATION DID NOT START${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  restorationMode never flipped to true after ${MAX_WAIT}s."
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Is Primary OM running with the JVM flag?"
    echo "       ps aux | grep 'restorationMode'"
    echo "    2. Is the local agent running with omBackupFeatureFlag=true?"
    echo "       grep omBackupFeatureFlag ~/mms-automation/go_planner/src/com.tengen/cm/main/local.config"
    echo "    3. Was the PITR restore done with an OLD snapshot (version < $PRE_DISASTER_VERSION)?"
    echo "    4. Check OM logs: grep -i 'restoration\\|pitr\\|mismatch' /tmp/primary-om.log"
    echo ""
fi

#!/bin/bash

# Deployment Reconciliation PoC — Phase 1: Verify Setup & Topology
#
# Verifies the environment is ready for reconciliation testing:
#   1. Infrastructure  (Meta OM, Primary OM, appDB)
#   2. Deployment topology  (target replica set node count & config version)
#   3. Feature flags  (OmBackupFeatureFlag, restorationMode)
#   4. Backup status in Meta OM
#   5. Saves baseline for post-reconciliation comparison
#
# Test scenario:
#   poRepSet starts with N nodes (snapshot taken) → scaled to N+M nodes →
#   disaster destroys appDB → restore from N-node snapshot →
#   reconciliation detects mismatch → converges to N+M nodes.
#
# Usage:
#   ./1-verify-setup.sh
#   PRIMARY_OM_PUBLIC_KEY=xxx PRIMARY_OM_PRIVATE_KEY=yyy ./1-verify-setup.sh
#
# ┌──────────────────────────────────────────────────────────────────────┐
# │ NOTE: Two feature flags MUST be enabled for reconciliation:        │
# │                                                                     │
# │ 1. Ops Manager (conf-hosted.properties or JVM override):           │
# │    mms.featureFlag.automation.restorationMode=enabled               │
# │                                                                     │
# │ 2. Automation agents managing the target replica set:              │
# │    omBackupFeatureFlag=true  (in automation-agent.config or CLI)    │
# └──────────────────────────────────────────────────────────────────────┘

echo "=== Deployment Reconciliation PoC — Phase 1: Verify Setup & Topology ==="
echo ""

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Configuration ───────────────────────────────────────────────────────────
META_OM_URL="http://localhost:8080"
PRIMARY_OM_URL="http://localhost:8081"
APPDB_CONTAINER="mongodb-ops-manager"
TARGET_RS="${TARGET_RS:-poRepSet}"   # Replica set we track for reconciliation

# Meta OM API credentials (digest auth)
META_PUBLIC_KEY="qyliqonz"
META_PRIVATE_KEY="165c22ab-f7e5-4869-9b9c-8811cbb2da1d"

# Primary OM API credentials (digest auth) — optional, set via env vars
# Create at: Primary OM UI → Access Manager → API Keys
PRIMARY_OM_PUBLIC_KEY="qpvglrut"
PRIMARY_OM_PRIVATE_KEY="c29d81bc-d02c-479c-aa6d-9888a7238443"

# Baseline state file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STATE_DIR="/tmp/reconciliation-poc"
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/baseline-${TIMESTAMP}.json"

# ─── Helpers ─────────────────────────────────────────────────────────────────
check_passed=0
check_failed=0
check_warned=0

pass() { echo -e "${GREEN}✓${NC} $1"; ((check_passed++)); }
fail() { echo -e "${RED}✗${NC} $1"; ((check_failed++)); }
warn() { echo -e "${YELLOW}⚠${NC} $1"; ((check_warned++)); }
info() { echo -e "  ${BLUE}→${NC} $1"; }

run_mongosh() {
    local eval_str="$1"
    # Prefer the agent-installed mongosh, fall back to container-bundled
    if docker exec "$APPDB_CONTAINER" test -f /var/lib/mongodb-mms-automation/bin/mongosh 2>/dev/null; then
        docker exec "$APPDB_CONTAINER" /var/lib/mongodb-mms-automation/bin/mongosh --quiet --eval "$eval_str" 2>/dev/null
    else
        docker exec "$APPDB_CONTAINER" mongosh --quiet --eval "$eval_str" 2>/dev/null
    fi
}

call_meta_api() {
    curl -s --digest -u "${META_PUBLIC_KEY}:${META_PRIVATE_KEY}" \
        "${META_OM_URL}/api/public/v1.0$1"
}

call_primary_api() {
    curl -s --digest -u "${PRIMARY_OM_PUBLIC_KEY}:${PRIMARY_OM_PRIVATE_KEY}" \
        "${PRIMARY_OM_URL}/api/public/v1.0$1"
}

# ═════════════════════════════════════════════════════════════════════════════
# 1. Infrastructure
# ═════════════════════════════════════════════════════════════════════════════
echo "1. Infrastructure"
echo "-----------------"

# Meta OM
if docker ps --format '{{.Names}}' | grep -q '^ops$'; then
    pass "Meta OM container running"
else
    fail "Meta OM container not running"
fi

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$META_OM_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|302|303)$ ]]; then
    pass "Meta OM accessible ($META_OM_URL)"
else
    fail "Meta OM not accessible ($META_OM_URL → HTTP $HTTP_CODE)"
fi

# Primary OM
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$PRIMARY_OM_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|302|303)$ ]]; then
    pass "Primary OM accessible ($PRIMARY_OM_URL)"
else
    fail "Primary OM not accessible ($PRIMARY_OM_URL → HTTP $HTTP_CODE)"
    info "Start with: cd /Users/prakhar.dhama/ops-manager && bazel run --server_env=hosted //server:mms"
fi

# appDB container
if docker ps --format '{{.Names}}' | grep -q "^${APPDB_CONTAINER}$"; then
    pass "appDB container running ($APPDB_CONTAINER)"
else
    fail "appDB container not running ($APPDB_CONTAINER)"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 2. appDB Replica Set
# ═════════════════════════════════════════════════════════════════════════════
echo "2. appDB Replica Set"
echo "--------------------"

RS_JSON=$(run_mongosh "
try {
    var s = rs.status();
    print(JSON.stringify({
        set: s.set,
        state: s.members[0].stateStr,
        member: s.members[0].name
    }));
} catch(e) { print(JSON.stringify({error: e.message})); }
" | tail -1 || echo '{"error":"unreachable"}')

if echo "$RS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('state')=='PRIMARY'" 2>/dev/null; then
    RS_SET=$(echo "$RS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['set'])")
    RS_MEMBER=$(echo "$RS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['member'])")
    pass "appDB replica set: $RS_SET (PRIMARY) — $RS_MEMBER"
else
    fail "appDB replica set not PRIMARY"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 3. Deployment Topology — target: $TARGET_RS
# ═════════════════════════════════════════════════════════════════════════════
echo "3. Deployment Topology (target: $TARGET_RS)"
echo "--------------------------------------------"

# ── 3a. Query appDB directly for automation config ──
CONFIG_JSON=$(run_mongosh "
var doc = db.getSiblingDB('automationcore').getCollection('config.automation').findOne({});
if (!doc) { print(JSON.stringify({error:'no config'})); quit(); }

var ver = doc.version;
if (typeof ver === 'object' && ver !== null) ver = Number(ver);

// Automation config stores processes under doc.cluster.processes (not doc.processes)
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

CONFIG_VERSION=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('configVersion',0))" 2>/dev/null || echo "?")
GROUP_ID=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('groupId',''))" 2>/dev/null || echo "?")
TARGET_PROCS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('targetProcesses',0))" 2>/dev/null || echo "0")
TARGET_MEMBERS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('targetMembers',0))" 2>/dev/null || echo "0")
TARGET_HOSTS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('targetHostnames',[])))" 2>/dev/null || echo "")
ALL_RS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('allReplicaSets',[])))" 2>/dev/null || echo "none")
TOTAL_PROCS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalProcesses',0))" 2>/dev/null || echo "0")

info "Automation config version: $CONFIG_VERSION"
info "Group ID: $GROUP_ID"
info "Total processes in config: $TOTAL_PROCS"
info "All replica sets: ${ALL_RS:-none}"

if [ "$TARGET_PROCS" -gt 0 ] 2>/dev/null; then
    pass "$TARGET_RS found: $TARGET_PROCS processes, $TARGET_MEMBERS members"
    info "Hosts: $TARGET_HOSTS"
else
    fail "$TARGET_RS not found in automation config (0 processes)"
    echo ""
    echo "  The deployment '$TARGET_RS' must exist in Primary OM before testing."
    echo "  Create it via Primary OM UI ($PRIMARY_OM_URL) or API."
    if [ "$TOTAL_PROCS" -eq 0 ] 2>/dev/null; then
        info "The automation config is empty — Primary OM may not have any deployments yet."
    fi
fi

# ── 3b. Optionally enrich with Primary OM API (shows managed hosts + agent status) ──
if [ -n "$PRIMARY_OM_PUBLIC_KEY" ] && [ -n "$PRIMARY_OM_PRIVATE_KEY" ] && [ -n "$GROUP_ID" ]; then
    echo ""
    info "Querying Primary OM API for live agent status..."
    AGENTS_JSON=$(call_primary_api "/groups/${GROUP_ID}/agents/AUTOMATION")
    AGENT_COUNT=$(echo "$AGENTS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo "?")
    info "Automation agents reporting to Primary OM: $AGENT_COUNT"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 4. Feature Flags
# ═════════════════════════════════════════════════════════════════════════════
echo "4. Feature Flags"
echo "----------------"

echo ""
echo "  ┌─ Ops Manager (Primary OM) ──────────────────────────────────────┐"
echo "  │ mms.featureFlag.automation.restorationMode                      │"
echo "  │                                                                  │"

# Check if the group has restorationMode field (schema is in place)
RESTORATION_FIELD=$(run_mongosh "
var grp = db.getSiblingDB('mmsdbconfig').getCollection('config.customers').findOne(
    {}, {restorationMode:1, restorationModeSetAt:1, restorationModeReason:1}
);
if (grp && grp.restorationMode !== undefined) {
    print(JSON.stringify({exists: true, value: grp.restorationMode}));
} else {
    print(JSON.stringify({exists: false}));
}
" | tail -1 || echo '{"exists":false}')

SCHEMA_EXISTS=$(echo "$RESTORATION_FIELD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exists',False))" 2>/dev/null || echo "False")
RESTORATION_VALUE=$(echo "$RESTORATION_FIELD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('value','N/A'))" 2>/dev/null || echo "N/A")

if [ "$SCHEMA_EXISTS" = "True" ]; then
    echo -e "  │ Schema:  ${GREEN}✓ restorationMode field present${NC} (current: $RESTORATION_VALUE)"
    echo "  │"
    ((check_passed++))
else
    echo -e "  │ Schema:  ${RED}✗ restorationMode field missing${NC}"
    echo "  │"
    ((check_failed++))
fi

# Detect the JVM flag by inspecting the running OM Java process command line
OM_FLAG_VALUE=$(ps aux | grep -o '\-Dmms.featureFlag.automation.restorationMode=[^ ]*' 2>/dev/null | head -1 || echo "")
if echo "$OM_FLAG_VALUE" | grep -q '=enabled'; then
    echo -e "  │ Runtime: ${GREEN}✓ JVM flag is ENABLED${NC}"
    echo "  │          ($OM_FLAG_VALUE)"
    echo "  │"
    ((check_passed++))
elif [ -n "$OM_FLAG_VALUE" ]; then
    echo -e "  │ Runtime: ${RED}✗ JVM flag set but NOT enabled${NC}"
    echo "  │          ($OM_FLAG_VALUE)"
    echo "  │"
    ((check_failed++))
else
    echo -e "  │ Runtime: ${RED}✗ JVM flag NOT FOUND in OM process${NC}"
    echo "  │          Primary OM may not be running, or was started without the flag."
    echo "  │"
    ((check_failed++))
fi

echo "  │ The flag MUST be 'enabled' (not 'disabled') at OM startup.     │"
echo "  │ Default in conf-hosted.properties is 'disabled'.               │"
echo "  │                                                                  │"
echo "  │ Enable via JVM override:                                        │"
echo "  │   bazel run --server_env=hosted //server:mms -- \\              │"
echo "  │     --jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled │"
echo "  │                                                                  │"
echo "  │ Or set env var before starting OM:                              │"
echo "  │   export MMSENV_MMS_FEATUREFLAG_AUTOMATION_RESTORATIONMODE=enabled  │"
echo "  └─────────────────────────────────────────────────────────────────┘"

echo ""
echo "  ┌─ Automation Agent (agents managing $TARGET_RS) ─────────────────┐"
echo "  │ omBackupFeatureFlag=true                                         │"
echo "  │                                                                  │"

AGENT_FLAG_FOUND=false

# Check 1: local agent config file (go run cm.go --config=local.config)
LOCAL_CONFIG="/Users/prakhar.dhama/mms-automation/go_planner/src/com.tengen/cm/main/local.config"
if [ -f "$LOCAL_CONFIG" ]; then
    AGENT_FLAG_LINE=$(grep -i "omBackupFeatureFlag" "$LOCAL_CONFIG" 2>/dev/null | tail -1)
    if echo "$AGENT_FLAG_LINE" | grep -qi "true"; then
        echo -e "  │ Config:  ${GREEN}✓ $AGENT_FLAG_LINE${NC}"
        echo "  │          (in local.config)"
        AGENT_FLAG_FOUND=true
        ((check_passed++))
    elif [ -n "$AGENT_FLAG_LINE" ]; then
        echo -e "  │ Config:  ${RED}✗ $AGENT_FLAG_LINE${NC}"
        echo "  │          (flag present but not true)"
        ((check_failed++))
    fi
fi

# Check 2: running agent process (go run cm.go or compiled binary)
if [ "$AGENT_FLAG_FOUND" = false ]; then
    AGENT_PROC=$(ps aux 2>/dev/null | grep -E "cm\.go|cm --config" | grep -v grep | head -1 || echo "")
    if [ -n "$AGENT_PROC" ]; then
        # Agent is running — check if its config has the flag
        AGENT_CFG=$(echo "$AGENT_PROC" | grep -oE '\-\-config=[^ ]+' | cut -d= -f2)
        if [ -n "$AGENT_CFG" ] && [ -f "$AGENT_CFG" ]; then
            AGENT_FLAG_LINE=$(grep -i "omBackupFeatureFlag" "$AGENT_CFG" 2>/dev/null | tail -1)
            if echo "$AGENT_FLAG_LINE" | grep -qi "true"; then
                echo -e "  │ Config:  ${GREEN}✓ $AGENT_FLAG_LINE${NC}"
                echo "  │          (in $AGENT_CFG)"
                AGENT_FLAG_FOUND=true
                ((check_passed++))
            fi
        fi
    fi
fi

# Check 3: docker container agents
if [ "$AGENT_FLAG_FOUND" = false ] && [ -n "$TARGET_HOSTS" ]; then
    SAMPLE_HOST=$(echo "$TARGET_HOSTS" | cut -d',' -f1 | cut -d':' -f1 | tr -d ' ')
    if docker exec "$SAMPLE_HOST" cat /etc/mongodb-mms/automation-agent.config 2>/dev/null | grep -qi "omBackupFeatureFlag.*true"; then
        AGENT_FLAG_VAL=$(docker exec "$SAMPLE_HOST" grep -i "omBackupFeatureFlag" /etc/mongodb-mms/automation-agent.config 2>/dev/null | tail -1)
        echo -e "  │ Config:  ${GREEN}✓ $AGENT_FLAG_VAL${NC}"
        echo "  │          (in container $SAMPLE_HOST)"
        AGENT_FLAG_FOUND=true
        ((check_passed++))
    fi
fi

# Check 4: running agent process with --omBackupFeatureFlag CLI flag
if [ "$AGENT_FLAG_FOUND" = false ]; then
    if ps aux 2>/dev/null | grep -v grep | grep -q "omBackupFeatureFlag"; then
        echo -e "  │ Process: ${GREEN}✓ flag found in running agent args${NC}"
        AGENT_FLAG_FOUND=true
        ((check_passed++))
    fi
fi

if [ "$AGENT_FLAG_FOUND" = false ]; then
    echo -e "  │ ${RED}✗ omBackupFeatureFlag not detected${NC}"
    echo "  │"
    echo "  │   Add to local.config:  omBackupFeatureFlag=true"
    echo "  │   Then restart:  go run cm.go --config=local.config"
    echo "  │"
    ((check_failed++))
fi

echo "  └─────────────────────────────────────────────────────────────────┘"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 5. Backup Status in Meta OM
# ═════════════════════════════════════════════════════════════════════════════
echo "5. Backup Status in Meta OM"
echo "---------------------------"

META_GROUPS=$(call_meta_api "/groups")
META_GROUP_ID=$(echo "$META_GROUPS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for g in data.get('results', []):
    print(g['id']); break
" 2>/dev/null || echo "")

if [ -n "$META_GROUP_ID" ]; then
    META_CLUSTERS=$(call_meta_api "/groups/${META_GROUP_ID}/clusters")
    META_CLUSTER_ID=$(echo "$META_CLUSTERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('results', []):
    if c.get('replicaSetName') == 'appdb-rs':
        print(c['id']); break
" 2>/dev/null || echo "")

    if [ -n "$META_CLUSTER_ID" ]; then
        SNAPSHOTS=$(call_meta_api "/groups/${META_GROUP_ID}/clusters/${META_CLUSTER_ID}/snapshots")
        SNAP_COUNT=$(echo "$SNAPSHOTS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo "0")

        if [ "$SNAP_COUNT" -gt 0 ] 2>/dev/null; then
            pass "Meta OM has $SNAP_COUNT snapshot(s) for appdb-rs"

            # Show latest snapshot
            echo "$SNAPSHOTS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
snaps = data.get('results', [])
if snaps:
    s = snaps[0]
    created = s.get('created', {}).get('date', 'N/A')
    complete = s.get('complete', False)
    sid = s.get('id', 'N/A')
    print(f'  Latest: {sid}  created={created}  complete={complete}')
" 2>/dev/null
        else
            fail "No snapshots found in Meta OM for appdb-rs"
            info "Enable backup: Meta OM UI → Continuous Backup → appdb-rs"
        fi
    else
        warn "Could not find appdb-rs cluster in Meta OM"
    fi
else
    warn "Could not query Meta OM API"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 6. Save Baseline
# ═════════════════════════════════════════════════════════════════════════════
echo "6. Save Baseline"
echo "----------------"

python3 << PYEOF
import json

def safe_int(val, default=0):
    try:
        return int(val)
    except (ValueError, TypeError):
        return default

baseline = {
    "timestamp": "${TIMESTAMP}",
    "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "configVersion": safe_int("${CONFIG_VERSION}"),
    "groupId": "${GROUP_ID}",
    "targetReplicaSet": "${TARGET_RS}",
    "targetProcessCount": safe_int("${TARGET_PROCS}"),
    "targetMemberCount": safe_int("${TARGET_MEMBERS}"),
    "targetHostnames": [h.strip() for h in "${TARGET_HOSTS}".split(",") if h.strip()],
    "allReplicaSets": [r.strip() for r in "${ALL_RS}".split(",") if r.strip() and r.strip() != "none"],
    "totalProcesses": safe_int("${TOTAL_PROCS}"),
}
with open("${STATE_FILE}", "w") as f:
    json.dump(baseline, f, indent=2)
print(json.dumps(baseline, indent=2))
PYEOF

echo ""
echo -e "Saved to: ${BLUE}$STATE_FILE${NC}"
# Also save a symlink to latest baseline for other scripts
ln -sf "$STATE_FILE" "${STATE_DIR}/baseline-latest.json"

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo "=== Summary ==="
echo ""
echo "Checks passed:  $check_passed"
echo "Checks failed:  $check_failed"
echo "Warnings:       $check_warned"
echo ""

if [ $check_failed -eq 0 ] && [ "$TARGET_PROCS" -gt 0 ] 2>/dev/null; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ SETUP VERIFIED — Ready for reconciliation testing${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Current state:"
    echo "  $TARGET_RS: $TARGET_PROCS nodes (config version $CONFIG_VERSION)"
    echo ""
    echo "Before proceeding, ensure:"
    echo "  1. A backup snapshot exists in Meta OM with the CURRENT config"
    echo "  2. Feature flags are enabled (see section 4 above)"
    echo ""
    echo "Next steps:"
    echo "  1. Scale $TARGET_RS (e.g. add 2 nodes via Primary OM UI)"
    echo "  2. Wait for agents to converge on the new config"
    echo "  3. Run: ./2-simulate-disaster.sh"
    echo ""
elif [ "$TARGET_PROCS" -eq 0 ] 2>/dev/null || [ "$TARGET_PROCS" = "0" ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠ DEPLOYMENT NOT FOUND — Setup required${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "To set up the reconciliation test:"
    echo "  1. Start Primary OM with restoration mode flag enabled:"
    echo "     cd /Users/prakhar.dhama/ops-manager"
    echo "     bazel run --server_env=hosted //server:mms -- \\"
    echo "       --jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled"
    echo ""
    echo "  2. Create a deployment '$TARGET_RS' (3-node replica set) in Primary OM"
    echo "     Primary OM UI: $PRIMARY_OM_URL"
    echo ""
    echo "  3. Ensure agents have omBackupFeatureFlag=true"
    echo ""
    echo "  4. Wait for a backup snapshot in Meta OM"
    echo ""
    echo "  5. Re-run this script to verify"
    echo ""
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}✗ SETUP INCOMPLETE — Fix issues above before proceeding${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi

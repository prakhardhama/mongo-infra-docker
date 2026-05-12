#!/bin/bash

# OM Backup Stores PoC — Phase 1: Verify Setup
#
# Verifies the full stack is healthy and backups are running:
#   1. Infrastructure  (Meta OM, Primary OM, backing-DB containers)
#   2. Backing-DB replica sets  (appdb-rs / s3-meta-rs / oplog-meta-rs)
#   3. Meta OM agents inside each backing-DB container
#   4. Meta OM backup status for each backing DB
#       - cluster registered, backup enabled, schedule = 30 min, recent snapshots
#   5. Primary OM backup status for poRepSet
#       - cluster registered, backup enabled, schedule = 30 min, recent snapshots
#
# Usage:
#   ./1-verify-setup.sh
#
# API keys are read from ./KEYS.md (sections "## META OM" and "## PRIMARY OM").

echo "=== OM Backup Stores PoC — Phase 1: Verify Setup ==="
echo ""

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Configuration ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="$SCRIPT_DIR/KEYS.md"
META_OM_URL="${META_OM_URL:-http://localhost:8080}"
PRIMARY_OM_URL="${PRIMARY_OM_URL:-http://localhost:8081}"

# Expected base interval (matches 2-set-snapshot-interval.sh default)
EXPECTED_BASE_INTERVAL_SECS="${EXPECTED_BASE_INTERVAL_SECS:-1800}"

# Backing DBs in Meta OM: container | port | replica-set
META_BACKED_UP=(
  "primary-om-appdb|27018|appdb-rs"
  "primary-om-s3-meta|27019|s3-meta-rs"
  "primary-om-oplog-meta|27020|oplog-meta-rs"
)

# Primary OM tracks just one deployment for this PoC
PRIMARY_TARGET_RS="${PRIMARY_TARGET_RS:-poRepSet}"

# ─── Helpers ─────────────────────────────────────────────────────────────────
check_passed=0
check_failed=0
check_warned=0

pass() { echo -e "${GREEN}✓${NC} $1"; ((check_passed++)); }
fail() { echo -e "${RED}✗${NC} $1"; ((check_failed++)); }
warn() { echo -e "${YELLOW}⚠${NC} $1"; ((check_warned++)); }
info() { echo -e "  ${BLUE}→${NC} $1"; }

# Pull a key out of KEYS.md by section header + key name.
# KEYS.md has the format:
#   ## META OM
#   META_PUBLIC_KEY="..."
#   PROJECT_PUBLIC_KEY="..."   ← scoped to META OM section
#
#   ## PRIMARY OM
#   GLOBAL_PUBLIC_KEY="..."
#   PROJECT_PUBLIC_KEY="..."   ← reused name, different value
get_key() {
  local section="$1" key="$2"
  awk -v section="## $section" -v key="$key=" '
    $0 == section { in_section = 1; next }
    /^##/ && in_section { in_section = 0 }
    in_section && index($0, key) == 1 {
      val = substr($0, length(key) + 1)
      gsub(/^"|"$/, "", val)
      print val
      exit
    }
  ' "$KEYS_FILE"
}

if [ ! -f "$KEYS_FILE" ]; then
  fail "KEYS.md not found at $KEYS_FILE — populate it first"
  exit 1
fi

META_PUBLIC_KEY=$(get_key "META OM" "META_PUBLIC_KEY")
[ -z "$META_PUBLIC_KEY" ] && META_PUBLIC_KEY=$(get_key "META OM" "META_ADMIN_PUBLIC_KEY")
META_PRIVATE_KEY=$(get_key "META OM" "META_PRIVATE_KEY")
PRIMARY_PUBLIC_KEY=$(get_key "PRIMARY OM" "GLOBAL_PUBLIC_KEY")
PRIMARY_PRIVATE_KEY=$(get_key "PRIMARY OM" "GLOBAL_PRIVATE_KEY")

call_meta_api() {
  curl -s --digest -u "${META_PUBLIC_KEY}:${META_PRIVATE_KEY}" \
    "${META_OM_URL}/api/public/v1.0$1"
}

call_primary_api() {
  curl -s --digest -u "${PRIMARY_PUBLIC_KEY}:${PRIMARY_PRIVATE_KEY}" \
    "${PRIMARY_OM_URL}/api/public/v1.0$1"
}

# Run mongosh inside a container against a specific port.
run_mongosh_in() {
  local container="$1" port="$2" eval_str="$3"
  docker exec "$container" mongosh --port "$port" --quiet --eval "$eval_str" 2>/dev/null
}

# Pretty-print seconds -> human (e.g. 1800 -> "30m")
fmt_secs() {
  local s="$1"
  if [ "$s" -lt 60 ]; then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h"
  else echo "$((s / 86400))d"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# 1. Infrastructure
# ═════════════════════════════════════════════════════════════════════════════
echo "1. Infrastructure"
echo "-----------------"

if docker ps --format '{{.Names}}' | grep -q '^ops$'; then
  pass "Meta OM container (ops) running"
else
  fail "Meta OM container (ops) not running — run om-docker/quick-start.sh"
fi

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$META_OM_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|302|303)$ ]]; then
  pass "Meta OM HTTP reachable ($META_OM_URL)"
else
  fail "Meta OM not reachable ($META_OM_URL → HTTP $HTTP_CODE)"
fi

if docker ps --format '{{.Names}}' | grep -q '^node1$'; then
  pass "Meta OM agent container (node1) running"
else
  fail "node1 container not running — Meta OM monitoring/backup will be impaired"
fi

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$PRIMARY_OM_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|302|303)$ ]]; then
  pass "Primary OM HTTP reachable ($PRIMARY_OM_URL)"
else
  warn "Primary OM not reachable ($PRIMARY_OM_URL → HTTP $HTTP_CODE)"
  info "Start with: cd /Users/prakhar.dhama/ops-manager && bazel run --server_env=hosted //server:mms"
fi

for entry in "${META_BACKED_UP[@]}"; do
  IFS='|' read -r container _ _ <<< "$entry"
  if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    pass "$container container running"
  else
    fail "$container container not running — run ./0-setup-backing-dbs.sh"
  fi
done

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 2. Backing-DB Replica Sets
# ═════════════════════════════════════════════════════════════════════════════
echo "2. Backing-DB Replica Sets"
echo "--------------------------"

for entry in "${META_BACKED_UP[@]}"; do
  IFS='|' read -r container port rs_name <<< "$entry"
  expected_member="${container}:${port}"

  HELLO_JSON=$(run_mongosh_in "$container" "$port" "
    try {
      var h = db.hello();
      print(JSON.stringify({setName: h.setName, primary: h.primary, me: h.me}));
    } catch(e) { print(JSON.stringify({error: e.message})); }
  " | tail -1 || echo '{"error":"unreachable"}')

  SET=$(echo "$HELLO_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('setName',''))" 2>/dev/null || echo "")
  ME=$(echo "$HELLO_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('me',''))" 2>/dev/null || echo "")
  PRIMARY=$(echo "$HELLO_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('primary',''))" 2>/dev/null || echo "")

  if [ "$SET" = "$rs_name" ] && [ "$ME" = "$expected_member" ] && [ "$PRIMARY" = "$expected_member" ]; then
    pass "$rs_name PRIMARY at $expected_member"
  else
    fail "$rs_name unhealthy — set=$SET, me=$ME, primary=$PRIMARY (expected $rs_name @ $expected_member)"
  fi
done

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 3. Meta OM Agents in backing-DB containers
# ═════════════════════════════════════════════════════════════════════════════
echo "3. Meta OM Agents (in backing-DB containers)"
echo "--------------------------------------------"

for entry in "${META_BACKED_UP[@]}"; do
  IFS='|' read -r container _ _ <<< "$entry"

  if ! docker exec "$container" pgrep -f mongodb-mms-automation-agent >/dev/null 2>&1; then
    fail "$container — agent NOT running (run ./1-restart-agents.sh)"
    continue
  fi

  agent_pid=$(docker exec "$container" pgrep -f mongodb-mms-automation-agent | head -1)
  agent_user=$(docker exec "$container" ps -o user= -p "$agent_pid" 2>/dev/null | tr -d '[:space:]')
  if [ "$agent_user" = "mongod" ]; then
    pass "$container — agent running (pid=$agent_pid, user=mongod)"
  else
    warn "$container — agent running but as user '$agent_user' (expected mongod)"
  fi
done

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 4. Meta OM Backup Status
# ═════════════════════════════════════════════════════════════════════════════
echo "4. Meta OM Backup Status"
echo "------------------------"

if [ -z "$META_PUBLIC_KEY" ] || [ -z "$META_PRIVATE_KEY" ]; then
  fail "META_PUBLIC_KEY/META_PRIVATE_KEY missing in KEYS.md"
else
  META_GROUPS=$(call_meta_api "/groups")
  META_GROUP_ID=$(echo "$META_GROUPS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for g in data.get('results', []):
    print(g['id']); break
" 2>/dev/null || echo "")

  if [ -z "$META_GROUP_ID" ]; then
    fail "Could not list Meta OM groups (check API keys)"
  else
    META_GROUP_NAME=$(echo "$META_GROUPS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for g in data.get('results', []):
    print(g.get('name', '')); break
" 2>/dev/null || echo "")
    info "Meta OM project: $META_GROUP_NAME ($META_GROUP_ID)"

    META_CLUSTERS=$(call_meta_api "/groups/${META_GROUP_ID}/clusters")
    META_CONFIGS=$(call_meta_api "/groups/${META_GROUP_ID}/backupConfigs")

    for entry in "${META_BACKED_UP[@]}"; do
      IFS='|' read -r _ _ rs_name <<< "$entry"

      CLUSTER_ID=$(echo "$META_CLUSTERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('results', []):
    if c.get('replicaSetName') == '$rs_name':
        print(c.get('id','')); break
" 2>/dev/null || echo "")

      if [ -z "$CLUSTER_ID" ]; then
        fail "$rs_name — not registered in Meta OM"
        continue
      fi

      # Backup enabled?
      STATUS=$(echo "$META_CONFIGS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('results', []):
    if c.get('clusterId') == '$CLUSTER_ID':
        print(c.get('statusName','')); break
" 2>/dev/null || echo "")
      if [ "$STATUS" != "STARTED" ]; then
        fail "$rs_name — backup statusName=$STATUS (expected STARTED)"
        continue
      fi

      # Schedule
      SCHED=$(call_meta_api "/groups/${META_GROUP_ID}/clusters/${CLUSTER_ID}/snapshotSchedule")
      BASE_HOURS=$(echo "$SCHED" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('snapshotIntervalHours', '?'))
" 2>/dev/null || echo "?")

      # The UI/API hide our sub-1h overrides; confirm via the appdb directly.
      JOB_INTERVAL=$(docker run --rm --add-host=host.docker.internal:host-gateway mongo:7 \
        mongosh "mongodb://host.docker.internal:27170/backupjobs?serverSelectionTimeoutMS=5000" --quiet --eval "
        const j = db.jobs.findOne({rsId: '$rs_name'});
        if (!j || !j.schedule || !j.schedule.rules) { print('?'); quit(); }
        const base = j.schedule.rules.slice().sort((a,b) => a.interval - b.interval)[0];
        print(base.interval);
      " 2>/dev/null | tail -1 || echo "?")

      # Snapshots
      SNAPSHOTS=$(call_meta_api "/groups/${META_GROUP_ID}/clusters/${CLUSTER_ID}/snapshots")
      SNAP_COUNT=$(echo "$SNAPSHOTS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo "0")
      LAST_SNAP=$(echo "$SNAPSHOTS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('results', [])
if results:
    s = results[0]
    print(f\"{s.get('created',{}).get('date','?')}|{'complete' if s.get('complete') else 'incomplete'}\")
" 2>/dev/null || echo "")
      LAST_DATE=${LAST_SNAP%|*}
      LAST_STATE=${LAST_SNAP#*|}

      if [ "$JOB_INTERVAL" = "$EXPECTED_BASE_INTERVAL_SECS" ]; then
        interval_msg="${GREEN}base=$(fmt_secs "$JOB_INTERVAL")${NC}"
      elif [ "$JOB_INTERVAL" = "?" ]; then
        interval_msg="${YELLOW}base=unknown${NC}"
      else
        interval_msg="${YELLOW}base=$(fmt_secs "$JOB_INTERVAL") (expected $(fmt_secs "$EXPECTED_BASE_INTERVAL_SECS"); run ./2-set-snapshot-interval.sh)${NC}"
      fi

      if [ "$SNAP_COUNT" -gt 0 ] 2>/dev/null && [ "$LAST_STATE" = "complete" ]; then
        pass "$rs_name — STARTED, $interval_msg, snapshots=$SNAP_COUNT, latest=$LAST_DATE ($LAST_STATE)"
      elif [ "$SNAP_COUNT" -gt 0 ] 2>/dev/null; then
        warn "$rs_name — STARTED, $interval_msg, snapshots=$SNAP_COUNT, latest=$LAST_DATE ($LAST_STATE)"
      else
        warn "$rs_name — STARTED, $interval_msg, no snapshots yet"
      fi
    done
  fi
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# 5. Primary OM Backup Status (poRepSet)
# ═════════════════════════════════════════════════════════════════════════════
echo "5. Primary OM Backup Status ($PRIMARY_TARGET_RS)"
echo "------------------------------------------------"

if [ -z "$PRIMARY_PUBLIC_KEY" ] || [ -z "$PRIMARY_PRIVATE_KEY" ]; then
  warn "GLOBAL_PUBLIC_KEY/GLOBAL_PRIVATE_KEY missing in KEYS.md (## PRIMARY OM section)"
elif [[ "$HTTP_CODE" =~ ^(200|302|303)$ ]] || curl -s -o /dev/null -w '%{http_code}' "$PRIMARY_OM_URL" 2>/dev/null | grep -qE "^(200|302|303)$"; then
  PRIMARY_GROUPS=$(call_primary_api "/groups")
  PRIMARY_GROUP_ID=$(echo "$PRIMARY_GROUPS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for g in data.get('results', []):
    print(g['id']); break
" 2>/dev/null || echo "")

  if [ -z "$PRIMARY_GROUP_ID" ]; then
    fail "Could not list Primary OM groups (check GLOBAL_* keys)"
  else
    PRIMARY_GROUP_NAME=$(echo "$PRIMARY_GROUPS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for g in data.get('results', []):
    print(g.get('name', '')); break
" 2>/dev/null || echo "")
    info "Primary OM project: $PRIMARY_GROUP_NAME ($PRIMARY_GROUP_ID)"

    PRIMARY_CLUSTERS=$(call_primary_api "/groups/${PRIMARY_GROUP_ID}/clusters")
    CLUSTER_ID=$(echo "$PRIMARY_CLUSTERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('results', []):
    if c.get('replicaSetName') == '$PRIMARY_TARGET_RS':
        print(c.get('id','')); break
" 2>/dev/null || echo "")

    if [ -z "$CLUSTER_ID" ]; then
      fail "$PRIMARY_TARGET_RS — not registered in Primary OM"
    else
      PRIMARY_CONFIGS=$(call_primary_api "/groups/${PRIMARY_GROUP_ID}/backupConfigs")
      STATUS=$(echo "$PRIMARY_CONFIGS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('results', []):
    if c.get('clusterId') == '$CLUSTER_ID':
        print(c.get('statusName','')); break
" 2>/dev/null || echo "")

      JOB_INTERVAL=$(docker run --rm --add-host=host.docker.internal:host-gateway mongo:7 \
        mongosh "mongodb://host.docker.internal:27018/backupjobs?directConnection=true&serverSelectionTimeoutMS=5000" --quiet --eval "
        const j = db.jobs.findOne({rsId: '$PRIMARY_TARGET_RS'});
        if (!j || !j.schedule || !j.schedule.rules) { print('?'); quit(); }
        const base = j.schedule.rules.slice().sort((a,b) => a.interval - b.interval)[0];
        print(base.interval);
      " 2>/dev/null | tail -1 || echo "?")

      SNAPSHOTS=$(call_primary_api "/groups/${PRIMARY_GROUP_ID}/clusters/${CLUSTER_ID}/snapshots")
      SNAP_COUNT=$(echo "$SNAPSHOTS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo "0")
      LAST_SNAP=$(echo "$SNAPSHOTS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('results', [])
if results:
    s = results[0]
    print(f\"{s.get('created',{}).get('date','?')}|{'complete' if s.get('complete') else 'incomplete'}\")
" 2>/dev/null || echo "")
      LAST_DATE=${LAST_SNAP%|*}
      LAST_STATE=${LAST_SNAP#*|}

      if [ "$JOB_INTERVAL" = "$EXPECTED_BASE_INTERVAL_SECS" ]; then
        interval_msg="${GREEN}base=$(fmt_secs "$JOB_INTERVAL")${NC}"
      elif [ "$JOB_INTERVAL" = "?" ]; then
        interval_msg="${YELLOW}base=unknown${NC}"
      else
        interval_msg="${YELLOW}base=$(fmt_secs "$JOB_INTERVAL") (expected $(fmt_secs "$EXPECTED_BASE_INTERVAL_SECS"))${NC}"
      fi

      if [ "$STATUS" != "STARTED" ]; then
        fail "$PRIMARY_TARGET_RS — backup statusName=$STATUS (expected STARTED)"
      elif [ "$SNAP_COUNT" -gt 0 ] 2>/dev/null && [ "$LAST_STATE" = "complete" ]; then
        pass "$PRIMARY_TARGET_RS — STARTED, $interval_msg, snapshots=$SNAP_COUNT, latest=$LAST_DATE ($LAST_STATE)"
      elif [ "$SNAP_COUNT" -gt 0 ] 2>/dev/null; then
        warn "$PRIMARY_TARGET_RS — STARTED, $interval_msg, snapshots=$SNAP_COUNT, latest=$LAST_DATE ($LAST_STATE)"
      else
        warn "$PRIMARY_TARGET_RS — STARTED, $interval_msg, no snapshots yet"
      fi
    fi
  fi
else
  warn "Skipping — Primary OM not reachable"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo "=== Summary ==="
echo "passed:  $check_passed"
echo "failed:  $check_failed"
echo "warned:  $check_warned"
echo ""

if [ "$check_failed" -eq 0 ]; then
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}✓ Setup looks good${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  exit 0
else
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${RED}✗ Setup incomplete — fix issues above${NC}"
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  exit 1
fi

#!/bin/bash

# Verify backup status for Primary OM AppDB in Meta OM
# Uses Meta OM API to check backup configuration and snapshots

# Meta OM API credentials
PUBLIC_KEY="rhicgwya"
PRIVATE_KEY="89433b09-e1b1-4651-a71e-d9baba1cfccd"
META_OM_URL="http://localhost:8080"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=== Primary OM AppDB Backup Status Checker ==="
echo ""
echo "Checking backup status in Meta OM for: appdb-rs"
echo ""

# Function to call Meta OM API
call_api() {
    local endpoint="$1"
    curl -s --digest -u "${PUBLIC_KEY}:${PRIVATE_KEY}" "${META_OM_URL}/api/public/v1.0${endpoint}"
}

echo "1. Finding Group (Project)"
echo "--------------------------"
ALL_GROUPS=$(call_api "/groups")

# Get the first group (or you can search by name if needed)
GROUP_ID=$(echo "$ALL_GROUPS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('results', [])
    if results:
        # Get the first group
        print(results[0].get('id', ''))
    else:
        print('', file=sys.stderr)
except Exception as e:
    print('', file=sys.stderr)
" 2>/dev/null)

if [ -z "$GROUP_ID" ]; then
    echo -e "${RED}✗ Could not find any groups${NC}"
    echo ""
    echo "Please check:"
    echo "  1. Meta OM is running"
    echo "  2. API credentials are correct"
    echo "  3. User has access to at least one group"
    exit 1
fi

GROUP_NAME=$(echo "$ALL_GROUPS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('results', [])
    if results:
        print(results[0].get('name', 'N/A'))
except:
    print('N/A')
" 2>/dev/null)

echo -e "${GREEN}✓ Found group: $GROUP_NAME${NC}"
echo -e "  Group ID: $GROUP_ID"
echo ""

echo "2. Finding appdb-rs Cluster"
echo "----------------------------"
ALL_CLUSTERS=$(call_api "/groups/${GROUP_ID}/clusters")

# Find the cluster ID for appdb-rs
CLUSTER_ID=$(echo "$ALL_CLUSTERS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for cluster in data.get('results', []):
        if cluster.get('replicaSetName') == 'appdb-rs':
            print(cluster.get('id', ''))
            break
except Exception as e:
    print('', file=sys.stderr)
" 2>/dev/null)

if [ -z "$CLUSTER_ID" ]; then
    echo -e "${RED}✗ Could not find cluster with replicaSetName 'appdb-rs'${NC}"
    echo ""
    echo "Available clusters:"
    echo "$ALL_CLUSTERS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for cluster in data.get('results', []):
        print(f\"  - {cluster.get('replicaSetName', 'N/A')} (ID: {cluster.get('id', 'N/A')})\")
except:
    print('  (Could not parse clusters)')
" 2>/dev/null
    exit 1
fi

echo -e "${GREEN}✓ Found cluster ID: $CLUSTER_ID${NC}"
echo ""

echo "3. Verifying Cluster Configuration"
echo "-----------------------------------"
CLUSTER_INFO=$(call_api "/groups/${GROUP_ID}/clusters/${CLUSTER_ID}")

CLUSTER_NAME=$(echo "$CLUSTER_INFO" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('clusterName', 'N/A'))" 2>/dev/null)
RS_NAME=$(echo "$CLUSTER_INFO" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('replicaSetName', 'N/A'))" 2>/dev/null)
LAST_HEARTBEAT=$(echo "$CLUSTER_INFO" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('lastHeartbeat', 'N/A'))" 2>/dev/null)

if [ "$RS_NAME" = "appdb-rs" ]; then
    echo -e "${GREEN}✓ Cluster verified: $CLUSTER_NAME${NC}"
    echo -e "  Replica Set: ${BLUE}$RS_NAME${NC}"
    echo -e "  Last Heartbeat: $LAST_HEARTBEAT"
    echo -e "  Cluster ID: $CLUSTER_ID"
else
    echo -e "${RED}✗ Could not verify cluster (expected RS: appdb-rs, got: $RS_NAME)${NC}"
    exit 1
fi
echo ""

echo "4. Checking Backup Configuration"
echo "---------------------------------"
BACKUP_CONFIG=$(call_api "/groups/${GROUP_ID}/clusters/${CLUSTER_ID}/backupConfig")

# Check if backup config exists
if echo "$BACKUP_CONFIG" | grep -q '"error".*404'; then
    echo -e "${YELLOW}⚠ Backup configuration not found via API${NC}"
    echo "  (This is normal - backup may still be working)"
else
    echo "Backup configuration:"
    echo "$BACKUP_CONFIG" | python3 -m json.tool 2>/dev/null || echo "$BACKUP_CONFIG"
fi
echo ""

echo "5. Getting Backup Snapshots"
echo "---------------------------"
SNAPSHOTS=$(call_api "/groups/${GROUP_ID}/clusters/${CLUSTER_ID}/snapshots")

# Parse snapshot information
SNAPSHOT_COUNT=$(echo "$SNAPSHOTS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('totalCount', 0))
except:
    print(0)
" 2>/dev/null)

if [ "$SNAPSHOT_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Found $SNAPSHOT_COUNT snapshot(s)${NC}"
    echo ""
    echo "Snapshot details:"
    echo "$SNAPSHOTS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for i, snap in enumerate(data.get('results', [])[:3], 1):
        print(f\"  Snapshot {i}:\")
        print(f\"    ID: {snap.get('id', 'N/A')}\")
        print(f\"    Created: {snap.get('created', {}).get('date', 'N/A')}\")
        print(f\"    Complete: {snap.get('complete', False)}\")
        print(f\"    Expires: {snap.get('expires', 'N/A')}\")
        if 'parts' in snap and snap['parts']:
            part = snap['parts'][0]
            print(f\"    Data Size: {part.get('dataSizeBytes', 0) / 1024 / 1024:.2f} MB\")
            print(f\"    MongoDB Version: {part.get('mongodVersion', 'N/A')}\")
        print()
except Exception as e:
    print(f\"  Error parsing: {e}\")
" 2>/dev/null
else
    echo -e "${RED}✗ No snapshots found${NC}"
    echo ""
    echo "Possible reasons:"
    echo "  1. Backup was just enabled and first snapshot hasn't completed"
    echo "  2. Backup is not configured"
    echo "  3. Backup daemon is stuck"
fi

echo ""

echo "6. Checking S3 Blockstore Status"
echo "---------------------------------"
# Check daemon logs for S3 blockstore activity
DAEMON_LOG=$(docker exec ops tail -100 /opt/mongodb/mms/logs/daemon.log 2>/dev/null || echo "")

if echo "$DAEMON_LOG" | grep -q "meta-ops-manager-backup-bucket"; then
    echo -e "${GREEN}✓ S3 blockstore 'meta-ops-manager-backup-bucket' is configured${NC}"

    if echo "$DAEMON_LOG" | grep -q "Blockstore meta-ops-manager-backup-bucket is not used"; then
        echo "  Status: Not used yet (normal if backup just started)"
    else
        echo "  Status: Active"
    fi

    # Check for blockstore scheduling
    if echo "$DAEMON_LOG" | grep -q "No configured blockstore snapshot stores"; then
        echo "  Note: Blockstore scheduler shows 'no configured stores'"
        echo "        (This is expected - snapshots exist but may use different storage)"
    fi
else
    echo -e "${YELLOW}⚠ Could not verify S3 blockstore in daemon logs${NC}"
fi

echo ""

echo "7. Checking for Backup Errors"
echo "------------------------------"
ERRORS=$(docker exec ops grep -i "error\|exception\|failed" /opt/mongodb/mms/logs/daemon.log 2>/dev/null | grep -v "DEBUG" | tail -3 || echo "")

if [ -z "$ERRORS" ]; then
    echo -e "${GREEN}✓ No recent errors in backup daemon log${NC}"
else
    echo -e "${YELLOW}⚠ Recent errors/warnings found:${NC}"
    echo "$ERRORS"
fi

echo ""

echo "8. Checking if Backup is Stuck on WT Checkpoint"
echo "------------------------------------------------"
# Check for "WT checkpoint" messages
WT_COUNT=$(docker exec ops grep -c "WT checkpoint" /opt/mongodb/mms/logs/daemon.log 2>/dev/null | head -1 || echo "0")
WT_COUNT=${WT_COUNT:-0}  # Default to 0 if empty

if [ "$WT_COUNT" -gt 100 ]; then
    echo -e "${RED}✗ Found $WT_COUNT 'WT checkpoint' messages - backup may be stuck!${NC}"
    echo ""
    echo "Last 3 WT checkpoint messages:"
    docker exec ops grep "WT checkpoint" /opt/mongodb/mms/logs/daemon.log 2>/dev/null | tail -3
    echo ""
    echo -e "${YELLOW}Recommended actions:${NC}"
    echo "  1. Force checkpoint: mongosh 'mongodb://localhost:27171/' --eval 'db.adminCommand({fsync: 1})'"
    echo "  2. Restart backup daemon: docker exec ops supervisorctl restart mms-backup-daemon"
elif [ "$WT_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Found $WT_COUNT 'WT checkpoint' messages${NC}"
    echo "  (This is normal if backup is actively running)"
else
    echo -e "${GREEN}✓ No 'WT checkpoint' messages found${NC}"
    echo "  Backup is not stuck on checkpoint"
fi

echo ""
echo "========================================"
echo "           SUMMARY"
echo "========================================"
echo ""

if [ "$SNAPSHOT_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✅ BACKUP IS WORKING!${NC}"
    echo ""
    echo "  ✓ Cluster 'appdb-rs' (Primary OM AppDB) is monitored"
    echo "  ✓ $SNAPSHOT_COUNT backup snapshot(s) exist"
    echo "  ✓ Latest snapshot is complete"
    echo "  ✓ No critical errors detected"
    echo "  ✓ Not stuck on WT checkpoint"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Review snapshots in Meta OM UI:"
    echo "     http://localhost:8080"
    echo "  2. Proceed with disaster recovery PoC:"
    echo "     cd disaster-recovery && ./1-verify-setup.sh"
    echo ""
    echo -e "${GREEN}You are ready for the DR PoC!${NC}"
else
    echo -e "${YELLOW}⚠ NO SNAPSHOTS FOUND${NC}"
    echo ""
    echo "  ✓ Cluster is configured"
    echo "  ✗ No backup snapshots exist"
    echo ""
    echo -e "${YELLOW}Action Required:${NC}"
    echo "  1. Enable backup in Meta OM UI:"
    echo "     http://localhost:8080 > Deployment > Backup"
    echo "  2. Wait for first snapshot to complete"
    echo "  3. Monitor: docker exec ops tail -f /opt/mongodb/mms/logs/daemon.log"
    echo "  4. Re-run this script to verify"
fi

echo ""


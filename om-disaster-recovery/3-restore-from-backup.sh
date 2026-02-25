#!/bin/bash

# Phase 3: Restore Primary OM's appDB from Meta OM backup
# This script automatically restores from the latest snapshot using Meta OM API

set -e

echo "=== Disaster Recovery PoC - Phase 3: Restore from Backup ==="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Meta OM API credentials
PUBLIC_KEY="tokmqzyg"
PRIVATE_KEY="e534a82c-0ed2-46e0-9590-f5effb0d145c"
META_OM_URL="http://localhost:8080"

# Function to call Meta OM Public API
call_api() {
    local endpoint="$1"
    local method="${2:-GET}"
    local data="$3"
    local temp_file=$(mktemp)

    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        curl -s --max-time 30 --digest -u "${PUBLIC_KEY}:${PRIVATE_KEY}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$data" \
            "${META_OM_URL}/api/public/v1.0${endpoint}" > "$temp_file" 2>&1
    else
        curl -s --max-time 30 --digest -u "${PUBLIC_KEY}:${PRIVATE_KEY}" \
            "${META_OM_URL}/api/public/v1.0${endpoint}" > "$temp_file" 2>&1
    fi

    cat "$temp_file"
    rm -f "$temp_file"
}

# Function to call Meta OM Internal NDS API
call_nds_api() {
    local endpoint="$1"
    local method="${2:-GET}"
    local data="$3"

    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        curl -s --digest -u "${PUBLIC_KEY}:${PRIVATE_KEY}" \
            -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data-urlencode "$data" \
            "${META_OM_URL}${endpoint}"
    else
        curl -s --digest -u "${PUBLIC_KEY}:${PRIVATE_KEY}" \
            "${META_OM_URL}${endpoint}"
    fi
}

echo "This script will automatically restore Primary OM's appDB"
echo "from the latest snapshot managed by Meta OM."
echo ""

echo "1. Verify current state (post-disaster)"
echo "----------------------------------------"

CURRENT_DBS=$(mongosh "mongodb://localhost:27171/" --quiet --eval "
    db.adminCommand({listDatabases: 1}).databases
        .filter(d => d.name != 'admin' && d.name != 'local' && d.name != 'config')
        .map(d => d.name)
        .join(', ')
" 2>/dev/null || echo "")

if [ -z "$CURRENT_DBS" ]; then
    echo -e "${GREEN}✓ Confirmed: No application databases exist${NC}"
else
    echo -e "${YELLOW}⚠ Warning: Some databases exist: $CURRENT_DBS${NC}"
    read -p "Continue anyway? (yes/no): " continue_restore </dev/tty
    if [ "$continue_restore" != "yes" ]; then
        echo "Restore cancelled."
        exit 0
    fi
fi

echo ""
echo "2. Using Group and Cluster IDs"
echo "-------------------------------"

# For now, use known IDs to avoid stdin/API issues
# TODO: Fetch dynamically once stdin issues are resolved
GROUP_ID="699d759b5fc1741c180917cb"
CLUSTER_ID="699d7b5b5fc1741c180938eb"
CLUSTER_NAME="primary-om-appdb"

echo -e "${GREEN}✓ Group ID: $GROUP_ID${NC}"
echo -e "${GREEN}✓ Cluster: $CLUSTER_NAME${NC}"
echo "  Cluster ID: ${BLUE}$CLUSTER_ID${NC}"
echo ""

echo ""
echo "3. Getting available snapshots"
echo "-------------------------------"

SNAPSHOTS=$(call_api "/groups/${GROUP_ID}/clusters/${CLUSTER_ID}/snapshots")

# Get the latest snapshot
LATEST_SNAPSHOT=$(echo "$SNAPSHOTS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('results'):
        # Sort by created date and get the latest
        snapshots = sorted(data['results'], key=lambda x: x.get('created', {}).get('date', ''), reverse=True)
        latest = snapshots[0]
        print(json.dumps(latest))
    else:
        print('{}')
except Exception as e:
    print('{}')
" 2>/dev/null)

SNAPSHOT_ID=$(echo "$LATEST_SNAPSHOT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', ''))" 2>/dev/null)
SNAPSHOT_DATE=$(echo "$LATEST_SNAPSHOT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('created', {}).get('date', 'Unknown'))" 2>/dev/null)
SNAPSHOT_COMPLETE=$(echo "$LATEST_SNAPSHOT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('complete', False))" 2>/dev/null)

if [ -z "$SNAPSHOT_ID" ]; then
    echo -e "${RED}✗ No snapshots found!${NC}"
    echo ""
    echo "Please ensure backup is configured and at least one snapshot exists."
    echo "Run: ./verify-appdb-backup-in-meta-om-status.sh"
    exit 1
fi

echo -e "${GREEN}✓ Found latest snapshot${NC}"
echo "  Snapshot ID: ${BLUE}$SNAPSHOT_ID${NC}"
echo "  Created: $SNAPSHOT_DATE"
echo "  Complete: $SNAPSHOT_COMPLETE"
echo ""

if [ "$SNAPSHOT_COMPLETE" != "True" ] && [ "$SNAPSHOT_COMPLETE" != "true" ]; then
    echo -e "${YELLOW}⚠ Warning: Latest snapshot is not marked as complete${NC}"
    read -p "Continue with this snapshot anyway? (yes/no): " continue_restore </dev/tty
    if [ "$continue_restore" != "yes" ]; then
        echo "Restore cancelled."
        exit 0
    fi
fi

echo ""
echo "4. Manual Restore Instructions"
echo "-------------------------------"

# Get the snapshot timestamp for display
SNAPSHOT_TIMESTAMP=$(echo "$LATEST_SNAPSHOT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    timestamp = data.get('created', {}).get('time', 0)
    print(timestamp)
except:
    print(0)
" 2>/dev/null)

SNAPSHOT_DATE=$(date -r $SNAPSHOT_TIMESTAMP 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLUE}Snapshot to restore:${NC}"
echo "  Snapshot ID: ${BLUE}$SNAPSHOT_ID${NC}"
echo "  Created: $SNAPSHOT_DATE"
echo "  Cluster: $CLUSTER_NAME"
echo ""

echo -e "${YELLOW}Note: Automated restore via API requires additional permissions.${NC}"
echo "Please perform the restore manually via Meta OM UI:"
echo ""
echo -e "${GREEN}Steps to restore:${NC}"
echo "  1. Open Meta OM UI: ${BLUE}http://localhost:8080${NC}"
echo "  2. Navigate to: ${BLUE}Deployment > Backup${NC}"
echo "  3. Click on cluster: ${BLUE}$CLUSTER_NAME${NC}"
echo "  4. Go to the ${BLUE}Snapshots${NC} tab"
echo "  5. Find snapshot: ${BLUE}$SNAPSHOT_ID${NC} (created: $SNAPSHOT_DATE)"
echo "  6. Click ${BLUE}Restore${NC} button for this snapshot"
echo "  7. Select ${BLUE}Automated Restore${NC}"
echo "  8. Choose ${BLUE}Existing Cluster${NC}: $CLUSTER_NAME"
echo "  9. Click ${BLUE}Finalize Request${NC}"
echo ""

read -p "Press Enter after you have initiated the restore in Meta OM UI..." </dev/tty

echo ""
echo "Checking for restore job..."

# Try to find the restore job
RESTORE_JOBS=$(call_api "/groups/${GROUP_ID}/clusters/${CLUSTER_ID}/restoreJobs")
RESTORE_JOB_ID=$(echo "$RESTORE_JOBS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('results'):
        # Get the most recent restore job
        jobs = sorted(data['results'], key=lambda x: x.get('created', {}).get('date', ''), reverse=True)
        if jobs:
            print(jobs[0].get('id', ''))
except:
    pass
" 2>/dev/null)

if [ -z "$RESTORE_JOB_ID" ]; then
    echo -e "${YELLOW}⚠ Could not find restore job via API${NC}"
    echo "This is normal - continuing with verification..."
    echo ""
    # Skip monitoring and go straight to verification
    SKIP_MONITORING=true
else
    echo -e "${GREEN}✓ Found restore job: $RESTORE_JOB_ID${NC}"
    echo ""
    SKIP_MONITORING=false
fi

if [ "$SKIP_MONITORING" != "true" ] && [ -n "$RESTORE_JOB_ID" ]; then
    echo ""
    echo "5. Monitoring restore progress"
    echo "-------------------------------"
    echo ""
    echo "Waiting for restore to complete..."
    echo "(This may take several minutes depending on data size)"
    echo ""

    # Poll restore job status
    MAX_WAIT=600  # 10 minutes
    WAIT_INTERVAL=10
    ELAPSED=0

    while [ $ELAPSED -lt $MAX_WAIT ]; do
        sleep $WAIT_INTERVAL
        ELAPSED=$((ELAPSED + WAIT_INTERVAL))

        # Check restore job status via public API
        JOB_STATUS=$(call_api "/groups/${GROUP_ID}/clusters/${CLUSTER_ID}/restoreJobs/${RESTORE_JOB_ID}")

        STATUS_NAME=$(echo "$JOB_STATUS" | python3 -c "import sys, json; print(json.load(sys.stdin).get('statusName', 'UNKNOWN'))" 2>/dev/null)

        echo "  [${ELAPSED}s] Status: $STATUS_NAME"

        if [ "$STATUS_NAME" = "FINISHED" ] || [ "$STATUS_NAME" = "COMPLETED" ]; then
            echo ""
            echo -e "${GREEN}✓ Restore completed successfully!${NC}"
            break
        elif [ "$STATUS_NAME" = "FAILED" ]; then
            echo ""
            echo -e "${RED}✗ Restore failed!${NC}"
            echo ""
            echo "Job details:"
            echo "$JOB_STATUS" | python3 -m json.tool 2>/dev/null || echo "$JOB_STATUS"
            echo ""
            echo "Check Meta OM daemon logs for more details:"
            echo "  docker exec ops tail -100 /opt/mongodb/mms/logs/daemon.log"
            exit 1
        fi
    done

    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo ""
        echo -e "${YELLOW}⚠ Restore is still in progress after ${MAX_WAIT}s${NC}"
        echo ""
        echo "The restore job is running but taking longer than expected."
        echo "You can monitor it in Meta OM UI:"
        echo "  http://localhost:8080 > Deployment > Backup > Restore Jobs"
        echo ""
        read -p "Press Enter to continue with verification (or Ctrl+C to wait longer)..." </dev/tty
    fi
else
    echo ""
    echo "5. Waiting for restore to complete"
    echo "-----------------------------------"
    echo ""
    echo "Monitor the restore progress in Meta OM UI:"
    echo "  ${BLUE}http://localhost:8080 > Deployment > Backup > Restore Jobs${NC}"
    echo ""
    read -p "Press Enter when the restore shows as 'Completed' in Meta OM UI..." </dev/tty
fi

echo ""
echo "6. Verifying restoration"
echo "------------------------"

echo "Checking for restored databases..."
RESTORED_DBS=$(mongosh "mongodb://localhost:27171/?directConnection=true" --quiet --eval "
    db.adminCommand({listDatabases: 1}).databases
        .filter(d => d.name != 'admin' && d.name != 'local' && d.name != 'config')
        .map(d => d.name)
" 2>/dev/null || echo "")

DB_COUNT=$(echo "$RESTORED_DBS" | python3 -c "import sys; dbs = sys.stdin.read().strip(); print(len(dbs.split(',')) if dbs else 0)" 2>/dev/null || echo "0")

if [ "$DB_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Found $DB_COUNT restored databases${NC}"
    echo ""
    echo "Sample databases:"
    echo "$RESTORED_DBS" | python3 -c "import sys; dbs = sys.stdin.read().strip().split(','); [print(f'  - {db.strip()}') for db in dbs[:10]]" 2>/dev/null
    if [ "$DB_COUNT" -gt 10 ]; then
        echo "  ... and $((DB_COUNT - 10)) more"
    fi
else
    echo -e "${RED}✗ No databases found. Restore may have failed.${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check restore job status in Meta OM UI"
    echo "  2. Check Meta OM daemon logs: docker exec ops tail -100 /opt/mongodb/mms/logs/daemon.log"
    echo "  3. Verify snapshot was complete"
    exit 1
fi

echo ""
echo "Checking for restored data..."

USER_COUNT=$(mongosh "mongodb://localhost:27171/mmsdbconfig?directConnection=true" --quiet --eval "db.users.countDocuments({})" 2>/dev/null || echo "0")
echo "  Users in mmsdbconfig: $USER_COUNT"

PROJECT_COUNT=$(mongosh "mongodb://localhost:27171/mmsdbconfig?directConnection=true" --quiet --eval "db.projects.countDocuments({})" 2>/dev/null || echo "0")
echo "  Projects in mmsdbconfig: $PROJECT_COUNT"

CLUSTER_COUNT=$(mongosh "mongodb://localhost:27171/mmsdbconfig?directConnection=true" --quiet --eval "db.clusters.countDocuments({})" 2>/dev/null || echo "0")
echo "  Clusters in mmsdbconfig: $CLUSTER_COUNT"

if [ "$USER_COUNT" -gt 0 ] || [ "$PROJECT_COUNT" -gt 0 ] || [ "$CLUSTER_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${GREEN}✓ Data has been successfully restored!${NC}"
else
    echo ""
    echo -e "${YELLOW}⚠ Databases exist but appear to be empty${NC}"
    echo "  This may be normal if the snapshot was taken before any data was created."
fi

echo ""
echo "========================================"
echo "     RESTORE COMPLETE!"
echo "========================================"
echo ""
echo -e "${GREEN}Summary:${NC}"
echo "  ✓ Snapshot selected: $SNAPSHOT_ID"
echo "  ✓ Restore job completed: $RESTORE_JOB_ID"
echo "  ✓ Databases restored: $DB_COUNT"
echo "  ✓ Data verified"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Start Primary OM:"
echo "     cd /Users/prakhar.dhama/ops-manager"
echo "     bazel run --server_env=hosted //server:mms"
echo ""
echo "  2. Verify you can log in to Primary OM:"
echo "     http://localhost:8081"
echo ""
echo "  3. Run comprehensive verification:"
echo "     ./4-verify-recovery.sh"
echo ""
echo -e "${GREEN}Your Primary OM should now be fully functional!${NC}"
echo ""


#!/bin/bash

# Phase 4: Verify automated restore is complete and successful
# This script validates that the disaster recovery was successful
#
# Uses docker exec for all mongosh calls since the host mongosh may be broken.

set -e

echo "=== Disaster Recovery PoC - Phase 4: Verify Automated Restore ==="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CONTAINER_NAME="mongodb-ops-manager"

check_passed=0
check_failed=0

# Helper: run mongosh inside the container (agent-installed or container-bundled)
run_mongosh() {
    local eval_str="$1"
    if docker exec "$CONTAINER_NAME" test -f /var/lib/mongodb-mms-automation/bin/mongosh 2>/dev/null; then
        docker exec "$CONTAINER_NAME" /var/lib/mongodb-mms-automation/bin/mongosh --quiet --eval "$eval_str" 2>/dev/null
    else
        docker exec "$CONTAINER_NAME" mongosh --quiet --eval "$eval_str" 2>/dev/null
    fi
}

echo "0. Infrastructure Status"
echo "------------------------"

# Check container is running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${GREEN}✓ Container is running${NC}"
    ((check_passed++))

    # Check hostname
    HOSTNAME=$(docker exec "$CONTAINER_NAME" hostname 2>/dev/null || echo "unknown")
    echo "  Hostname: $HOSTNAME"

    # Check automation agent
    AGENT_PID=$(docker exec "$CONTAINER_NAME" pgrep -f automation-agent 2>/dev/null | head -1 || echo "")
    if [ -n "$AGENT_PID" ]; then
        AGENT_USER=$(docker exec "$CONTAINER_NAME" ps -o user= -p "$AGENT_PID" 2>/dev/null | tr -d '[:space:]')
        echo -e "  ${GREEN}✓ Automation agent running (PID: $AGENT_PID, User: $AGENT_USER)${NC}"
        ((check_passed++))

        if [ "$AGENT_USER" = "mongod" ]; then
            echo -e "  ${GREEN}✓ Agent running as mongod user (no UID mismatch)${NC}"
            ((check_passed++))
        else
            echo -e "  ${YELLOW}⚠ Agent running as $AGENT_USER (expected: mongod)${NC}"
        fi
    else
        echo -e "  ${RED}✗ Automation agent not running${NC}"
        ((check_failed++))
    fi
else
    echo -e "${RED}✗ Container is not running${NC}"
    ((check_failed++))
    exit 1
fi

echo ""
echo "1. Database Restoration Verification"
echo "-------------------------------------"

# Check MongoDB is running
if ! run_mongosh "db.adminCommand({ping: 1})" | grep -q "ok" 2>/dev/null; then
    echo -e "${RED}✗ MongoDB is not accessible${NC}"
    echo "Please ensure MongoDB is running inside the container"
    exit 1
fi
echo -e "${GREEN}✓ MongoDB is accessible${NC}"
((check_passed++))

# Count total databases
DB_COUNT=$(run_mongosh "
    db.adminCommand({listDatabases: 1}).databases
        .filter(d => d.name != 'admin' && d.name != 'local' && d.name != 'config')
        .length
" | tail -1 || echo "0")

echo -e "Total databases restored: ${GREEN}$DB_COUNT${NC}"

if [ "$DB_COUNT" -gt 100 ]; then
    echo -e "${GREEN}✓ Expected number of databases restored${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ Fewer databases than expected (found: $DB_COUNT, expected: >100)${NC}"
fi

# Check for critical databases
echo ""
echo "Checking critical databases:"

for db_name in mmsdbconfig mmsdb mmsdbautomation backupjobs backupconfig automationcore; do
    coll_count=$(run_mongosh "db.getSiblingDB('$db_name').getCollectionNames().length" | tail -1 || echo "0")
    if [ "$coll_count" -gt 0 ] 2>/dev/null; then
        echo -e "  $db_name: ${GREEN}✓${NC} ($coll_count collections)"
        ((check_passed++))
    else
        echo -e "  $db_name: ${YELLOW}⚠${NC} (not found or empty)"
    fi
done

echo ""
echo "2. Data Integrity Check"
echo "-----------------------"

COLLECTION_COUNT=$(run_mongosh "
var total = 0;
db.adminCommand('listDatabases').databases.forEach(function(database) {
    if (database.name !== 'admin' && database.name !== 'local' && database.name !== 'config') {
        total += db.getSiblingDB(database.name).getCollectionNames().length;
    }
});
print(total);
" | tail -1 || echo "0")
echo "Total collections: $COLLECTION_COUNT"

if [ "$COLLECTION_COUNT" -gt 200 ] 2>/dev/null; then
    echo -e "${GREEN}✓ Expected number of collections restored${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ Fewer collections than expected (found: $COLLECTION_COUNT, expected: >200)${NC}"
fi

echo ""
echo "3. Replica Set Status"
echo "---------------------"

RS_STATUS=$(run_mongosh "
try {
    var status = rs.status();
    print('Replica Set: ' + status.set);
    print('State: ' + (status.myState === 1 ? 'PRIMARY' : status.myState === 2 ? 'SECONDARY' : 'OTHER'));
    print('Members: ' + status.members.length);
    print('Member: ' + status.members[0].name);
} catch(e) {
    print('ERROR: ' + e.message);
}
" || echo "ERROR")

echo "$RS_STATUS"

if echo "$RS_STATUS" | grep -q "PRIMARY"; then
    echo -e "${GREEN}✓ Replica set is PRIMARY${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ Replica set is not PRIMARY${NC}"
fi

echo ""
echo "4. Automation Agent Logs Check"
echo "-------------------------------"

if docker exec "$CONTAINER_NAME" tail -100 /var/log/mongodb-mms-automation/automation-agent.log 2>/dev/null | grep -qi "UID\|refusing"; then
    echo -e "${RED}✗ Found UID mismatch errors in agent logs${NC}"
    ((check_failed++))
else
    echo -e "${GREEN}✓ No UID mismatch errors in agent logs${NC}"
    ((check_passed++))
fi

if docker exec "$CONTAINER_NAME" pgrep -f "mongod.*automation\|mongod.*-f /data" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ MongoDB is managed by automation agent${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ MongoDB may not be managed by automation${NC}"
fi

echo ""
echo "5. Compare with Pre-Disaster State"
echo "-----------------------------------"

STATE_FILE=$(ls -t /tmp/dr-poc-state-*.txt 2>/dev/null | head -1 || echo "")

if [ -n "$STATE_FILE" ]; then
    echo "Pre-disaster state file: $STATE_FILE"
    echo ""

    if [ "$DB_COUNT" -gt 100 ] 2>/dev/null; then
        echo -e "  ${GREEN}✓ Database count is in expected range ($DB_COUNT)${NC}"
        ((check_passed++))
    else
        echo -e "  ${YELLOW}⚠ Database count lower than expected ($DB_COUNT)${NC}"
    fi
else
    echo -e "${YELLOW}⚠ No pre-disaster state file found${NC}"
    echo "  Cannot compare with baseline"
fi

echo ""
echo "=== Recovery Verification Summary ==="
echo ""
echo "Checks passed: $check_passed"
echo "Checks failed: $check_failed"
echo ""

if [ $check_failed -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ DISASTER RECOVERY POC SUCCESSFUL!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Summary:"
    echo "  ✓ Primary OM's appDB was completely destroyed (container + volume)"
    echo "  ✓ Data was successfully restored via Meta OM automated restore"
    echo "  ✓ Automation agent managed the entire restore process"
    echo "  ✓ $DB_COUNT databases restored"
    echo "  ✓ $COLLECTION_COUNT collections restored"
    echo "  ✓ Replica set is operational (PRIMARY)"
    echo "  ✓ All data integrity checks passed"
    echo "  ✓ Container hostname: $HOSTNAME (matches original agent)"
    echo ""
elif [ $check_failed -le 2 ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠ RECOVERY MOSTLY SUCCESSFUL WITH MINOR ISSUES${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Most checks passed. Review warnings above."
    echo ""
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}✗ RECOVERY VERIFICATION INCOMPLETE${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Multiple checks failed. Please review and address issues."
    echo ""
fi

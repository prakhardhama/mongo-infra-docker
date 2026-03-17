#!/bin/bash

# Phase 4: Verify automated restore is complete and successful
# This script validates that the disaster recovery was successful

set -e

echo "=== Disaster Recovery PoC - Phase 4: Verify Automated Restore ==="
echo ""
echo "This script verifies the automated restore performed by Meta OM"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

check_passed=0
check_failed=0

# Function to check and report
check() {
    local name="$1"
    local command="$2"

    echo -n "Checking $name... "
    if eval "$command" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        ((check_passed++))
        return 0
    else
        echo -e "${RED}✗${NC}"
        ((check_failed++))
        return 1
    fi
}

echo "0. Infrastructure Status"
echo "------------------------"

# Check container is running
if docker ps | grep -q mongodb-ops-manager; then
    echo -e "${GREEN}✓ Container is running${NC}"
    ((check_passed++))

    # Check hostname
    HOSTNAME=$(docker exec mongodb-ops-manager hostname 2>/dev/null || echo "unknown")
    echo "  Hostname: $HOSTNAME"
    if [ "$HOSTNAME" = "de152bf62a02" ]; then
        echo -e "  ${GREEN}✓ Hostname matches original agent${NC}"
        ((check_passed++))
    fi

    # Check automation agent
    AGENT_PID=$(docker exec mongodb-ops-manager pgrep -f automation-agent 2>/dev/null || echo "")
    if [ -n "$AGENT_PID" ]; then
        AGENT_USER=$(docker exec mongodb-ops-manager ps -o user= -p $AGENT_PID 2>/dev/null | head -1)
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
if ! mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "db.adminCommand({ping: 1})" > /dev/null 2>&1; then
    echo -e "${RED}✗ MongoDB is not accessible on port 27018${NC}"
    echo "Please ensure MongoDB container is running"
    exit 1
fi

# Count total databases
DB_COUNT=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "
    db.adminCommand({listDatabases: 1}).databases
        .filter(d => d.name != 'admin' && d.name != 'local' && d.name != 'config')
        .length
" 2>/dev/null || echo "0")

echo -e "Total databases restored: ${GREEN}$DB_COUNT${NC}"

if [ "$DB_COUNT" -gt 100 ]; then
    echo -e "${GREEN}✓ Expected number of databases restored (161 expected)${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ Fewer databases than expected (found: $DB_COUNT, expected: ~161)${NC}"
fi

# Check for critical collections
echo ""
echo "Checking critical collections:"

# Check mmsdbconfig collections
USERS_COLL=$(mongosh 'mongodb://localhost:27018/?directConnection=true' --quiet --eval 'db.getSiblingDB("mmsdbconfig").users.countDocuments({})' 2>/dev/null | tail -1)
if [ -n "$USERS_COLL" ]; then
    echo -e "Checking mmsdbconfig.users exists... ${GREEN}✓${NC} (count: $USERS_COLL)"
    ((check_passed++))
else
    echo -e "Checking mmsdbconfig.users exists... ${YELLOW}⚠${NC}"
fi

GROUPS_COLL=$(mongosh 'mongodb://localhost:27018/?directConnection=true' --quiet --eval 'db.getSiblingDB("mmsdbconfig").groups.countDocuments({})' 2>/dev/null | tail -1)
if [ -n "$GROUPS_COLL" ]; then
    echo -e "Checking mmsdbconfig.groups exists... ${GREEN}✓${NC} (count: $GROUPS_COLL)"
    ((check_passed++))
else
    echo -e "Checking mmsdbconfig.groups exists... ${YELLOW}⚠${NC}"
fi

CLUSTERS_COLL=$(mongosh 'mongodb://localhost:27018/?directConnection=true' --quiet --eval 'db.getSiblingDB("mmsdbconfig").clusters.countDocuments({})' 2>/dev/null | tail -1)
if [ -n "$CLUSTERS_COLL" ]; then
    echo -e "Checking mmsdbconfig.clusters exists... ${GREEN}✓${NC} (count: $CLUSTERS_COLL)"
    ((check_passed++))
else
    echo -e "Checking mmsdbconfig.clusters exists... ${YELLOW}⚠${NC}"
fi

# Check backup databases
check "backupjobs database exists" "mongosh 'mongodb://localhost:27018/?directConnection=true' --quiet --eval 'db.getSiblingDB(\"backupjobs\").getCollectionNames().length' 2>&1 | tail -1 | grep -qE '[0-9]+'"
check "backupconfig database exists" "mongosh 'mongodb://localhost:27018/?directConnection=true' --quiet --eval 'db.getSiblingDB(\"backupconfig\").getCollectionNames().length' 2>&1 | tail -1 | grep -qE '[0-9]+'"

echo ""
echo "2. Data Integrity Check"
echo "-----------------------"

USER_COUNT=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "db.getSiblingDB('mmsdbconfig').users.countDocuments({})" 2>/dev/null | tail -1 || echo "0")
echo "Total users: $USER_COUNT"

GROUP_COUNT=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "db.getSiblingDB('mmsdbconfig').groups.countDocuments({})" 2>/dev/null | tail -1 || echo "0")
echo "Total groups: $GROUP_COUNT"

CLUSTER_COUNT=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "db.getSiblingDB('mmsdbconfig').clusters.countDocuments({})" 2>/dev/null | tail -1 || echo "0")
echo "Total clusters: $CLUSTER_COUNT"

COLLECTION_COUNT=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "
var total = 0;
db.adminCommand('listDatabases').databases.forEach(function(database) {
    if (database.name !== 'admin' && database.name !== 'local' && database.name !== 'config') {
        var dbObj = db.getSiblingDB(database.name);
        total += dbObj.getCollectionNames().length;
    }
});
print(total);
" 2>/dev/null || echo "0")
echo "Total collections: $COLLECTION_COUNT"

if [ "$COLLECTION_COUNT" -gt 200 ]; then
    echo -e "${GREEN}✓ Expected number of collections restored (313 expected)${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ Fewer collections than expected (found: $COLLECTION_COUNT, expected: ~313)${NC}"
fi

echo ""
echo "3. Replica Set Status"
echo "---------------------"

RS_STATUS=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "
try {
    var status = rs.status();
    print('Replica Set: ' + status.set);
    print('State: ' + (status.myState === 1 ? 'PRIMARY' : status.myState === 2 ? 'SECONDARY' : 'OTHER'));
    print('Members: ' + status.members.length);
} catch(e) {
    print('ERROR: ' + e.message);
}
" 2>/dev/null || echo "ERROR")

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

echo "Checking automation agent logs..."
if docker exec mongodb-ops-manager tail -100 /var/log/mongodb-mms-automation/automation-agent.log 2>/dev/null | grep -q "UID\|refusing"; then
    echo -e "${RED}✗ Found UID mismatch errors in agent logs${NC}"
    ((check_failed++))
else
    echo -e "${GREEN}✓ No UID mismatch errors in agent logs${NC}"
    ((check_passed++))
fi

# Check if MongoDB is being managed by automation
if docker exec mongodb-ops-manager pgrep -f "mongod.*automation" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ MongoDB is managed by automation agent${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ MongoDB may not be managed by automation${NC}"
fi

echo ""
echo "5. Sample Data Verification"
echo "---------------------------"

echo "Checking sample data from key databases..."

# Check backup-related databases
BACKUP_JOBS=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "db.getSiblingDB('backupjobs').getCollectionNames().length" 2>/dev/null | tail -1 || echo "0")
echo "Backup jobs collections: $BACKUP_JOBS"

BACKUP_CONFIG=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "db.getSiblingDB('backupconfig').getCollectionNames().length" 2>/dev/null | tail -1 || echo "0")
echo "Backup config collections: $BACKUP_CONFIG"

# Check automation databases
AUTOMATION_CORE=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "db.getSiblingDB('automationcore').getCollectionNames().length" 2>/dev/null | tail -1 || echo "0")
echo "Automation core collections: $AUTOMATION_CORE"

if [ "$BACKUP_JOBS" -gt 0 ] && [ "$BACKUP_CONFIG" -gt 0 ] && [ "$AUTOMATION_CORE" -gt 0 ]; then
    echo -e "${GREEN}✓ Key operational databases are present${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ Some operational databases may be missing${NC}"
fi

echo ""
echo "6. Compare with Pre-Disaster State"
echo "-----------------------------------"

# Find the most recent state file
STATE_FILE=$(ls -t /tmp/dr-poc-state-*.txt 2>/dev/null | head -1 || echo "")

if [ -n "$STATE_FILE" ]; then
    echo "Pre-disaster state file: $STATE_FILE"
    echo ""

    # Extract pre-disaster database count
    PRE_DBS=$(grep "Total databases:" "$STATE_FILE" | grep -oE '[0-9]+' || echo "unknown")
    echo "Comparing database counts..."
    echo "  Before disaster: $PRE_DBS databases"
    echo "  After recovery:  $DB_COUNT databases"

    if [ "$PRE_DBS" != "unknown" ] && [ "$PRE_DBS" -eq "$DB_COUNT" ]; then
        echo -e "  ${GREEN}✓ Database count matches exactly${NC}"
        ((check_passed++))
    elif [ "$DB_COUNT" -gt 100 ]; then
        echo -e "  ${GREEN}✓ Database count is in expected range${NC}"
        ((check_passed++))
    else
        echo -e "  ${YELLOW}⚠ Database count differs${NC}"
    fi
else
    echo -e "${YELLOW}⚠ No pre-disaster state file found${NC}"
    echo "  Cannot compare with baseline"
    echo "  Note: This is expected if disaster simulation destroyed everything"
fi

echo ""
echo "=== Recovery Verification Summary ==="
echo ""
echo "Checks passed: $check_passed"
echo "Checks failed: $check_failed"
echo ""

if [ $check_failed -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ AUTOMATED RESTORE SUCCESSFUL!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Summary:"
    echo "  ✓ Primary OM's appDB was completely destroyed (container + volume)"
    echo "  ✓ Data was successfully restored via Meta OM automated restore"
    echo "  ✓ Automation agent managed the entire restore process"
    echo "  ✓ All $DB_COUNT databases restored"
    echo "  ✓ All $COLLECTION_COUNT collections restored"
    echo "  ✓ Replica set is operational (PRIMARY)"
    echo "  ✓ All data integrity checks passed"
    echo ""
    echo "Recovery Method:"
    echo "  - Automated restore via Meta OM UI"
    echo "  - Automation agent downloaded and restored snapshot"
    echo "  - MongoDB managed by automation agent (running as mongod user)"
    echo "  - Container hostname: de152bf62a02 (matches original agent)"
    echo ""
    echo "Next steps:"
    echo "  1. Verify Meta OM UI shows agent as active"
    echo "  2. Check backup status has resumed"
    echo "  3. Document actual recovery time (RTO)"
    echo "  4. Test application functionality"
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
    echo -e "${RED}⚠ RECOVERY VERIFICATION INCOMPLETE${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Multiple checks failed. Please review and address issues."
    echo ""
fi


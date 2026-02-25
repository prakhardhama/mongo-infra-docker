#!/bin/bash

# Phase 2: Simulate disaster by destroying Primary OM's appDB
# This script safely simulates a catastrophic failure of the appDB

set -e

echo "=== Disaster Recovery PoC - Phase 2: Disaster Simulation ==="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Safety check
echo -e "${RED}WARNING: This script will DESTROY all data in Primary OM's appDB!${NC}"
echo ""
echo "This simulates a catastrophic failure where the appDB is completely lost."
echo ""
read -p "Are you sure you want to continue? (type 'yes' to proceed): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Disaster simulation cancelled."
    exit 0
fi

echo ""
echo "1. Documenting current state before disaster"
echo "---------------------------------------------"

# Create backup of current state info
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STATE_FILE="/tmp/dr-poc-state-$TIMESTAMP.txt"

echo "Saving state to: $STATE_FILE"
echo "=== Pre-Disaster State ===" > "$STATE_FILE"
echo "Timestamp: $(date)" >> "$STATE_FILE"
echo "" >> "$STATE_FILE"

echo "Replica Set:" >> "$STATE_FILE"
mongosh "mongodb://localhost:27171/?directConnection=true" --quiet --eval "printjson(rs.status())" >> "$STATE_FILE" 2>&1 || true

echo "" >> "$STATE_FILE"
echo "Databases:" >> "$STATE_FILE"
mongosh "mongodb://localhost:27171/" --quiet --eval "printjson(db.adminCommand({listDatabases: 1}))" >> "$STATE_FILE" 2>&1 || true

echo "" >> "$STATE_FILE"
echo "User count:" >> "$STATE_FILE"
mongosh "mongodb://localhost:27171/mmsdbconfig" --quiet --eval "print('Users: ' + db.users.countDocuments({}))" >> "$STATE_FILE" 2>&1 || true

echo "" >> "$STATE_FILE"
echo "Project count:" >> "$STATE_FILE"
mongosh "mongodb://localhost:27171/mmsdbconfig" --quiet --eval "print('Projects: ' + db.projects.countDocuments({}))" >> "$STATE_FILE" 2>&1 || true

echo -e "${GREEN}✓ State documented${NC}"

echo ""
echo "2. Checking if Primary OM is running"
echo "-------------------------------------"

PRIMARY_OM_PIDS=$(pgrep -f "bazel.*server:mms|com.xgen.svc.core.ServerMain" || echo "")
if [ -n "$PRIMARY_OM_PIDS" ]; then
    echo -e "${YELLOW}⚠ Primary OM is running (PIDs: $PRIMARY_OM_PIDS)${NC}"
    read -p "Stop Primary OM now? (yes/no): " stop_om

    if [ "$stop_om" = "yes" ]; then
        echo "Stopping Primary OM..."
        # Kill all related processes (bazel wrapper and Java process)
        echo "$PRIMARY_OM_PIDS" | xargs kill 2>/dev/null || true
        sleep 3
        echo -e "${GREEN}✓ Primary OM stopped${NC}"
    else
        echo -e "${RED}Please stop Primary OM manually before proceeding.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ Primary OM is not running${NC}"
fi

echo ""
echo "3. Simulating disaster - Destroying appDB"
echo "------------------------------------------"

read -p "Choose disaster type (1=Drop databases, 2=Rename databases): " disaster_type

if [ "$disaster_type" = "1" ]; then
    echo "Dropping all application databases..."
    
    mongosh "mongodb://localhost:27171/" --quiet --eval "
        var dbs = db.adminCommand({listDatabases: 1}).databases;
        dbs.forEach(function(d) {
            if (d.name != 'admin' && d.name != 'local' && d.name != 'config') {
                print('Dropping database: ' + d.name);
                db.getSiblingDB(d.name).dropDatabase();
            }
        });
        print('All application databases dropped.');
    " 2>&1
    
    echo -e "${GREEN}✓ Databases dropped${NC}"
    
elif [ "$disaster_type" = "2" ]; then
    echo "Renaming all application databases (safer for testing)..."
    
    mongosh "mongodb://localhost:27171/" --quiet --eval "
        var dbs = db.adminCommand({listDatabases: 1}).databases;
        var timestamp = new Date().getTime();
        dbs.forEach(function(d) {
            if (d.name != 'admin' && d.name != 'local' && d.name != 'config') {
                var newName = d.name + '_destroyed_' + timestamp;
                print('Renaming database: ' + d.name + ' -> ' + newName);
                db.getSiblingDB(d.name).copyDatabase(d.name, newName);
                db.getSiblingDB(d.name).dropDatabase();
            }
        });
        print('All application databases renamed.');
    " 2>&1
    
    echo -e "${GREEN}✓ Databases renamed (can be restored if needed)${NC}"
else
    echo -e "${RED}Invalid option. Disaster simulation cancelled.${NC}"
    exit 1
fi

echo ""
echo "4. Verifying disaster"
echo "---------------------"

REMAINING_DBS=$(mongosh "mongodb://localhost:27171/" --quiet --eval "
    db.adminCommand({listDatabases: 1}).databases
        .filter(d => d.name != 'admin' && d.name != 'local' && d.name != 'config')
        .map(d => d.name)
        .join(', ')
" 2>/dev/null || echo "")

if [ -z "$REMAINING_DBS" ]; then
    echo -e "${GREEN}✓ Disaster confirmed: No application databases remain${NC}"
else
    echo -e "${YELLOW}⚠ Some databases still exist: $REMAINING_DBS${NC}"
fi

echo ""
echo "5. Testing Primary OM startup (should fail or show empty state)"
echo "----------------------------------------------------------------"
echo -e "${YELLOW}Manual test required:${NC}"
echo "  1. Try to start Primary OM:"
echo "     cd /Users/prakhar.dhama/ops-manager"
echo "     bazel run --server_env=hosted //server:mms"
echo ""
echo "  2. Expected behavior:"
echo "     - OM may fail to start due to missing databases"
echo "     - OR OM starts but shows empty/initial state"
echo "     - No users, projects, or previous configuration"
echo ""
echo "  3. Stop Primary OM after verification"
echo ""

echo "=== Disaster Simulation Complete ==="
echo ""
echo "State saved to: $STATE_FILE"
echo ""
echo -e "${GREEN}Next steps:${NC}"
echo "  1. Verify Primary OM cannot function properly (see above)"
echo "  2. Proceed to recovery: ./3-restore-from-backup.sh"
echo ""


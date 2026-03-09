#!/bin/bash

# Phase 1: Verify current setup and backup configuration
# This script checks that all components are running and backups are configured

set -e

echo "=== Disaster Recovery PoC - Phase 1: Setup Verification ==="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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

echo "1. Checking Docker Services"
echo "----------------------------"
check "Meta OM container running" "docker ps | grep -q 'ops'"
check "Meta OM accessible on port 8080" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080 | grep -q '200\|302\|303'"

echo ""
echo "2. Checking MongoDB Services"
echo "-----------------------------"
check "Primary OM appDB accessible on 27018" "mongosh 'mongodb://localhost:27018/?directConnection=true' --quiet --eval 'db.adminCommand({ping: 1})' 2>&1 | grep -q 'ok: 1'"
check "Primary OM appDB container running" "docker ps | grep -q 'mongodb-ops-manager'"

echo ""
echo "3. Checking Replica Set Configuration"
echo "--------------------------------------"
RS_NAME=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "rs.status().set" 2>/dev/null || echo "")
if [ -n "$RS_NAME" ]; then
    echo -e "Replica Set Name: ${GREEN}$RS_NAME${NC}"
    ((check_passed++))
else
    echo -e "${RED}✗ Could not determine replica set name${NC}"
    ((check_failed++))
fi

RS_MEMBER=$(mongosh "mongodb://localhost:27018/?directConnection=true" --quiet --eval "rs.status().members[0].name" 2>/dev/null || echo "")
if [ -n "$RS_MEMBER" ]; then
    echo -e "Replica Set Member: ${GREEN}$RS_MEMBER${NC}"
    ((check_passed++))
else
    echo -e "${RED}✗ Could not determine replica set member${NC}"
    ((check_failed++))
fi

echo ""
echo "4. Checking Primary OM appDB Databases"
echo "---------------------------------------"
DBS=$(mongosh "mongodb://localhost:27018/" --quiet --eval "db.adminCommand({listDatabases: 1}).databases.map(d => d.name).join(', ')" 2>/dev/null || echo "")
if [ -n "$DBS" ]; then
    echo -e "Databases: ${GREEN}$DBS${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ No databases found (Primary OM may not be initialized yet)${NC}"
fi

echo ""
echo "5. Checking for Test Data"
echo "-------------------------"
USER_COUNT=$(mongosh "mongodb://localhost:27018/mmsdbconfig" --quiet --eval "db.users.countDocuments({})" 2>/dev/null || echo "0")
echo "Users in mmsdbconfig: $USER_COUNT"

PROJECT_COUNT=$(mongosh "mongodb://localhost:27018/mmsdbconfig" --quiet --eval "db.groups.countDocuments({})" 2>/dev/null || echo "0")
echo "Groups in mmsdbconfig: $PROJECT_COUNT"

echo ""
echo "6. Backup Configuration Check"
echo "------------------------------"
echo -e "${YELLOW}⚠ Manual check required:${NC}"
echo "  1. Open Meta OM UI: http://localhost:8080"
echo "  2. Navigate to: Deployment > Backup"
echo "  3. Verify that Primary OM's appDB replica set is listed"
echo "  4. Check that at least one snapshot exists"
echo ""
echo "  Replica Set to look for: $RS_NAME"
echo ""

echo "=== Summary ==="
echo "Checks passed: $check_passed"
echo "Checks failed: $check_failed"
echo ""

if [ $check_failed -eq 0 ]; then
    echo -e "${GREEN}✓ All automated checks passed!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Verify backup configuration in Meta OM UI (see above)"
    echo "  2. Create test data in Primary OM if not already done"
    echo "  3. Wait for at least one backup snapshot to complete"
    echo "  4. Run: ./2-simulate-disaster.sh"
    exit 0
else
    echo -e "${RED}✗ Some checks failed. Please fix issues before proceeding.${NC}"
    exit 1
fi


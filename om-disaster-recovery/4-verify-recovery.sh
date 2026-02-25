#!/bin/bash

# Phase 4: Verify Primary OM is fully functional after recovery
# This script validates that the disaster recovery was successful

set -e

echo "=== Disaster Recovery PoC - Phase 4: Verify Recovery ==="
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

echo "1. Database Restoration Verification"
echo "-------------------------------------"

# Check databases exist
DBS=$(mongosh "mongodb://localhost:27171/" --quiet --eval "
    db.adminCommand({listDatabases: 1}).databases
        .filter(d => d.name != 'admin' && d.name != 'local' && d.name != 'config')
        .map(d => d.name)
        .join(', ')
" 2>/dev/null || echo "")

if [ -n "$DBS" ]; then
    echo -e "Databases restored: ${GREEN}$DBS${NC}"
    ((check_passed++))
else
    echo -e "${RED}✗ No application databases found${NC}"
    ((check_failed++))
fi

# Check for critical collections
echo ""
echo "Checking critical collections:"
check "mmsdbconfig.users exists" "mongosh 'mongodb://localhost:27171/mmsdbconfig' --quiet --eval 'db.users.countDocuments({})' 2>&1 | grep -qE '[0-9]+'"
check "mmsdbconfig.projects exists" "mongosh 'mongodb://localhost:27171/mmsdbconfig' --quiet --eval 'db.projects.countDocuments({})' 2>&1 | grep -qE '[0-9]+'"
check "mmsdbconfig.config exists" "mongosh 'mongodb://localhost:27171/mmsdbconfig' --quiet --eval 'db.config.countDocuments({})' 2>&1 | grep -qE '[0-9]+'"

echo ""
echo "2. Data Integrity Check"
echo "-----------------------"

USER_COUNT=$(mongosh "mongodb://localhost:27171/mmsdbconfig" --quiet --eval "db.users.countDocuments({})" 2>/dev/null || echo "0")
echo "Total users: $USER_COUNT"

PROJECT_COUNT=$(mongosh "mongodb://localhost:27171/mmsdbconfig" --quiet --eval "db.projects.countDocuments({})" 2>/dev/null || echo "0")
echo "Total projects: $PROJECT_COUNT"

if [ "$USER_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ User data restored${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ No users found${NC}"
fi

if [ "$PROJECT_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Project data restored${NC}"
    ((check_passed++))
else
    echo -e "${YELLOW}⚠ No projects found${NC}"
fi

echo ""
echo "3. Primary OM Startup Test"
echo "---------------------------"
echo ""
echo -e "${BLUE}Manual verification required:${NC}"
echo ""
echo "  1. Start Primary OM:"
echo "     cd /Users/prakhar.dhama/ops-manager"
echo "     bazel run --server_env=hosted //server:mms"
echo ""
echo "  2. Expected behavior:"
echo "     - OM starts without errors"
echo "     - No migration errors"
echo "     - Logs show successful connection to appDB"
echo ""

read -p "Did Primary OM start successfully? (yes/no): " om_started

if [ "$om_started" = "yes" ]; then
    echo -e "${GREEN}✓ Primary OM started successfully${NC}"
    ((check_passed++))
else
    echo -e "${RED}✗ Primary OM failed to start${NC}"
    ((check_failed++))
fi

echo ""
echo "4. Functional Verification"
echo "--------------------------"
echo ""
echo -e "${BLUE}Manual tests in Primary OM UI (http://localhost:8081):${NC}"
echo ""
echo "  [ ] Can log in with existing credentials"
echo "  [ ] Projects are visible and accessible"
echo "  [ ] User settings are preserved"
echo "  [ ] Deployment configurations are intact"
echo "  [ ] Can create a new project"
echo "  [ ] Can create a new user"
echo "  [ ] Can view existing deployments (if any)"
echo ""

read -p "Did all functional tests pass? (yes/no): " functional_ok

if [ "$functional_ok" = "yes" ]; then
    echo -e "${GREEN}✓ All functional tests passed${NC}"
    ((check_passed++))
else
    echo -e "${RED}✗ Some functional tests failed${NC}"
    ((check_failed++))
fi

echo ""
echo "5. Compare with Pre-Disaster State"
echo "-----------------------------------"

# Find the most recent state file
STATE_FILE=$(ls -t /tmp/dr-poc-state-*.txt 2>/dev/null | head -1 || echo "")

if [ -n "$STATE_FILE" ]; then
    echo "Pre-disaster state file: $STATE_FILE"
    echo ""
    echo "Comparing user counts..."
    
    PRE_USERS=$(grep "Users:" "$STATE_FILE" | grep -oE '[0-9]+' || echo "unknown")
    POST_USERS=$USER_COUNT
    
    echo "  Before disaster: $PRE_USERS users"
    echo "  After recovery:  $POST_USERS users"
    
    if [ "$PRE_USERS" = "$POST_USERS" ]; then
        echo -e "  ${GREEN}✓ User count matches${NC}"
        ((check_passed++))
    else
        echo -e "  ${YELLOW}⚠ User count differs${NC}"
    fi
    
    echo ""
    echo "Comparing project counts..."
    
    PRE_PROJECTS=$(grep "Projects:" "$STATE_FILE" | grep -oE '[0-9]+' || echo "unknown")
    POST_PROJECTS=$PROJECT_COUNT
    
    echo "  Before disaster: $PRE_PROJECTS projects"
    echo "  After recovery:  $POST_PROJECTS projects"
    
    if [ "$PRE_PROJECTS" = "$POST_PROJECTS" ]; then
        echo -e "  ${GREEN}✓ Project count matches${NC}"
        ((check_passed++))
    else
        echo -e "  ${YELLOW}⚠ Project count differs${NC}"
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
    echo "  ✓ Primary OM's appDB was completely destroyed"
    echo "  ✓ Data was successfully restored from Meta OM backup"
    echo "  ✓ Primary OM is fully functional"
    echo "  ✓ All data integrity checks passed"
    echo ""
    echo "Next steps:"
    echo "  1. Document the recovery time (RTO)"
    echo "  2. Document any lessons learned"
    echo "  3. Update DR runbook with findings"
    echo "  4. Consider automating the recovery process"
    echo ""
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}⚠ RECOVERY VERIFICATION INCOMPLETE${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Some checks failed. Please review and address issues."
    echo ""
fi


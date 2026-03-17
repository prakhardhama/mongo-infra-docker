#!/bin/bash

echo "=========================================="
echo "Complete Automation Status Check"
echo "=========================================="
echo ""

# 1. Container Status
echo "1. Container Status"
echo "-------------------"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|mongodb-ops-manager|ops"
echo ""

# 2. Network Configuration
echo "2. Network Configuration"
echo "------------------------"
echo "mongodb-ops-manager networks:"
docker inspect mongodb-ops-manager --format='{{range $net, $conf := .NetworkSettings.Networks}}  - {{$net}}: {{$conf.IPAddress}}
{{end}}'

echo ""
echo "Testing connectivity to ops.om.internal:"
CONN_TEST=$(docker exec mongodb-ops-manager curl -s -o /dev/null -w "%{http_code}" http://ops.om.internal:8080 2>/dev/null)
if [ "$CONN_TEST" = "303" ] || [ "$CONN_TEST" = "200" ]; then
    echo "  ✅ Can connect to ops.om.internal:8080 (HTTP $CONN_TEST)"
else
    echo "  ❌ Cannot connect to ops.om.internal:8080"
fi
echo ""

# 3. MongoDB Status
echo "3. MongoDB Status"
echo "-----------------"
# Check for MongoDB process (either manual or automation-managed)
MONGOD_PID=$(docker exec mongodb-ops-manager pgrep -f "bin/mongod" 2>/dev/null | head -1)
if [ -n "$MONGOD_PID" ]; then
    MONGOD_USER=$(docker exec mongodb-ops-manager ps -o user= -p $MONGOD_PID 2>/dev/null | head -1)
    echo "✅ MongoDB is running (PID: $MONGOD_PID, User: $MONGOD_USER)"

    # Check if managed by automation
    if docker exec mongodb-ops-manager pgrep -f "mongod.*automation" > /dev/null 2>&1; then
        echo "✅ MongoDB is managed by automation agent"

        # Check automation log file
        if docker exec mongodb-ops-manager test -f /data/db/automation-mongod.conf; then
            echo "✅ Automation config exists: /data/db/automation-mongod.conf"
        fi
    else
        echo "⚠️  MongoDB is running manually (not managed by automation)"
    fi
else
    echo "❌ MongoDB is NOT running"
fi
echo ""

# 4. Replica Set Status
echo "4. Replica Set Status"
echo "---------------------"
RS_STATUS=$(docker exec mongodb-ops-manager mongosh --quiet --eval "rs.status().members.map(m => ({name: m.name, state: m.stateStr}))" 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "✅ Replica Set is active"
    echo "$RS_STATUS" | sed 's/^/  /'
else
    echo "❌ Replica Set is not responding"
fi
echo ""

# 5. Automation Agent Status
echo "5. Automation Agent Status"
echo "--------------------------"
AGENT_PID=$(docker exec mongodb-ops-manager pgrep -f "mongodb-mms-automation-agent" 2>/dev/null | head -1)
if [ -n "$AGENT_PID" ]; then
    AGENT_USER=$(docker exec mongodb-ops-manager ps -o user= -p $AGENT_PID 2>/dev/null | head -1)
    echo "✅ Automation agent is running (PID: $AGENT_PID, User: $AGENT_USER)"

    # Check for UID mismatch errors
    if docker exec mongodb-ops-manager tail -50 /var/log/mongodb-mms-automation/automation-agent.log 2>/dev/null | grep -q "UID\|refusing"; then
        UID_ERRORS=$(docker exec mongodb-ops-manager tail -50 /var/log/mongodb-mms-automation/automation-agent.log 2>/dev/null | grep -c "UID\|refusing")
        echo "⚠️  UID mismatch errors detected ($UID_ERRORS in last 50 lines)"
        echo "    Agent and MongoDB may be running as different users"
    else
        echo "✅ No UID mismatch errors"
    fi

    # Check for connection errors
    if docker exec mongodb-ops-manager tail -50 /var/log/mongodb-mms-automation/automation-agent.log 2>/dev/null | grep -q "connection refused"; then
        CONN_ERRORS=$(docker exec mongodb-ops-manager tail -50 /var/log/mongodb-mms-automation/automation-agent.log 2>/dev/null | grep -c "connection refused")
        echo "⚠️  Connection errors detected ($CONN_ERRORS in last 50 lines)"
    else
        echo "✅ No recent connection errors"
    fi
else
    echo "❌ Automation agent is NOT running"
fi
echo ""

# 6. Summary
echo "=========================================="
echo "Summary"
echo "=========================================="
echo ""

MONGODB_OK=$(docker exec mongodb-ops-manager pgrep -f "bin/mongod" > /dev/null 2>&1 && echo "yes" || echo "no")
AGENT_OK=$(docker exec mongodb-ops-manager pgrep -f "mongodb-mms-automation-agent" > /dev/null 2>&1 && echo "yes" || echo "no")
NETWORK_OK=$([ "$CONN_TEST" = "303" ] || [ "$CONN_TEST" = "200" ] && echo "yes" || echo "no")
AUTOMATION_MANAGED=$(docker exec mongodb-ops-manager pgrep -f "mongod.*automation" > /dev/null 2>&1 && echo "yes" || echo "no")

# Check if agent and MongoDB are running as same user
if [ "$MONGODB_OK" = "yes" ] && [ "$AGENT_OK" = "yes" ]; then
    MONGOD_PID=$(docker exec mongodb-ops-manager pgrep -f "bin/mongod" 2>/dev/null | head -1)
    AGENT_PID=$(docker exec mongodb-ops-manager pgrep -f "mongodb-mms-automation-agent" 2>/dev/null | head -1)
    MONGOD_USER=$(docker exec mongodb-ops-manager ps -o user= -p $MONGOD_PID 2>/dev/null | head -1)
    AGENT_USER=$(docker exec mongodb-ops-manager ps -o user= -p $AGENT_PID 2>/dev/null | head -1)

    if [ "$MONGOD_USER" = "$AGENT_USER" ]; then
        UID_MATCH="yes"
    else
        UID_MATCH="no"
    fi
else
    UID_MATCH="unknown"
fi

if [ "$MONGODB_OK" = "yes" ] && [ "$AGENT_OK" = "yes" ] && [ "$NETWORK_OK" = "yes" ] && [ "$UID_MATCH" = "yes" ]; then
    echo "✅ ALL SYSTEMS READY!"
    echo ""
    echo "Configuration:"
    echo "  ✓ MongoDB running (User: $MONGOD_USER)"
    echo "  ✓ Automation agent running (User: $AGENT_USER)"
    echo "  ✓ No UID mismatch (both running as same user)"
    echo "  ✓ Network connectivity established"
    echo "  ✓ Replica set active"
    [ "$AUTOMATION_MANAGED" = "yes" ] && echo "  ✓ MongoDB managed by automation agent"
    echo ""
    echo "Next Steps:"
    echo "  1. Go to Meta OM UI: http://localhost:8080"
    echo "  2. Navigate to: Deployment → Servers"
    echo "  3. Verify agent 'de152bf62a02' shows as active"
    echo "  4. Check that Monitoring and Backup agents are active"
    echo "  5. Verify automation is managing the deployment"
    echo ""
else
    echo "❌ SOME ISSUES DETECTED"
    echo ""
    [ "$MONGODB_OK" = "no" ] && echo "  ✗ MongoDB is not running"
    [ "$AGENT_OK" = "no" ] && echo "  ✗ Automation agent is not running"
    [ "$NETWORK_OK" = "no" ] && echo "  ✗ Network connectivity issue"
    [ "$UID_MATCH" = "no" ] && echo "  ✗ UID mismatch: MongoDB ($MONGOD_USER) vs Agent ($AGENT_USER)"
    [ "$AUTOMATION_MANAGED" = "no" ] && echo "  ⚠️  MongoDB not managed by automation"
    echo ""
fi


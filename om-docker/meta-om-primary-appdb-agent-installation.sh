#!/bin/bash
set -e  # Exit on error

# Configuration from Meta OM
AGENT_API_KEY="69a131d9de116a0d710fa0ff30672ffafb86aa8470096267164c5085"
GROUP_ID="69a13144de116a0d710fa00a"
MMS_BASE_URL="http://ops.om.internal:8080"

echo "=========================================="
echo "MongoDB Agent Installation Script"
echo "=========================================="
echo "Target: mongodb-ops-manager container"
echo "Group ID: ${GROUP_ID}"
echo "API Key: ${AGENT_API_KEY:0:10}..." # Show only first 10 chars for security
echo "Base URL: ${MMS_BASE_URL}"
echo ""

# Verify containers are running
echo "==> Verifying containers..."
if ! docker ps | grep -q "^.*mongodb-ops-manager"; then
    echo "ERROR: mongodb-ops-manager container is not running"
    exit 1
fi

if ! docker ps | grep -q "^.*ops"; then
    echo "ERROR: Meta OM (ops) container is not running"
    exit 1
fi
echo "✓ Both containers are running"
echo ""

# Detect the agent tarball in Meta OM container
echo "==> Detecting ARM64 agent in Meta OM container..."
AGENT_TARBALL=$(docker exec ops bash -c "ls /opt/mongodb/mms/agent/automation/*aarch64.tar.gz 2>/dev/null | head -1" || echo "")

if [ -z "$AGENT_TARBALL" ]; then
    echo "ERROR: No ARM64 agent tarball found in Meta OM container"
    echo "Expected location: /opt/mongodb/mms/agent/automation/*aarch64.tar.gz"
    echo ""
    echo "Available agents:"
    docker exec ops ls -1 /opt/mongodb/mms/agent/automation/*.tar.gz 2>/dev/null | grep aarch64 || echo "  None found"
    exit 1
fi

echo "✓ Found agent: $AGENT_TARBALL"
AGENT_FILENAME=$(basename "$AGENT_TARBALL")
AGENT_DIR="${AGENT_FILENAME%.tar.gz}"
echo "  Agent directory: $AGENT_DIR"
echo ""

# Copy agent from Meta OM container to host
echo "==> Copying agent from Meta OM container to host..."
docker cp "ops:$AGENT_TARBALL" "/tmp/mongodb-agent.tar.gz"
echo "✓ Copied to /tmp/mongodb-agent.tar.gz"
echo ""

# Copy from host to mongodb-ops-manager container
echo "==> Copying agent to mongodb-ops-manager container..."
docker cp /tmp/mongodb-agent.tar.gz mongodb-ops-manager:/tmp/mongodb-agent.tar.gz
echo "✓ Copied to container"
echo ""

# Install required system packages
echo "==> Installing required system packages..."
docker exec -u root mongodb-ops-manager bash -c "
yum install -y hostname procps-ng > /dev/null 2>&1 || echo '  → Packages may already be installed'
"
echo "✓ System packages installed"
echo ""

# Stop any existing agent before installation
echo "==> Stopping any existing agent..."
docker exec -u root mongodb-ops-manager bash -c "
set +e  # Don't exit on error for this section
if command -v pkill > /dev/null 2>&1; then
    if pgrep -f mongodb-mms-automation-agent > /dev/null 2>&1; then
        pkill -f mongodb-mms-automation-agent
        sleep 2
        echo \"  → Existing agents stopped\"
    else
        echo \"  → No agents running\"
    fi
else
    echo \"  → pkill not available, skipping\"
fi
set -e  # Re-enable exit on error
" || true
echo ""

# Install and configure the agent in mongodb-ops-manager container
echo "==> Installing agent in mongodb-ops-manager container..."
docker exec -u root mongodb-ops-manager bash -c "
set -e

cd /tmp

# Clean up any previous extraction
echo '  → Cleaning up previous extractions...'
rm -rf mongodb-mms-automation-agent-* 2>/dev/null || true

# Extract the agent
echo '  → Extracting agent tarball...'
tar -xzf mongodb-agent.tar.gz

# Find the extracted directory (it may vary by version)
EXTRACTED_DIR=\$(ls -d mongodb-mms-automation-agent-* 2>/dev/null | head -1)
if [ -z \"\$EXTRACTED_DIR\" ]; then
    echo 'ERROR: Failed to find extracted agent directory'
    exit 1
fi
echo \"  → Found extracted directory: \$EXTRACTED_DIR\"

# Install the agent binaries
echo '  → Installing agent binaries...'
mkdir -p /opt/mongodb-mms-automation/bin
cp -f \"\$EXTRACTED_DIR/mongodb-mms-automation-agent\" /opt/mongodb-mms-automation/bin/
cp -f \"\$EXTRACTED_DIR/fatallogger\" /opt/mongodb-mms-automation/bin/ 2>/dev/null || echo '  → fatallogger not found (optional)'
chmod +x /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent
[ -f /opt/mongodb-mms-automation/bin/fatallogger ] && chmod +x /opt/mongodb-mms-automation/bin/fatallogger

# Create required directories
echo '  → Creating configuration directories...'
mkdir -p /etc/mongodb-mms
mkdir -p /var/log/mongodb-mms-automation
mkdir -p /var/lib/mongodb-mms-automation

# Set proper ownership (use mongod user if exists, otherwise root)
if id mongod &>/dev/null; then
    chown -R mongod:mongod /var/log/mongodb-mms-automation
    chown -R mongod:mongod /var/lib/mongodb-mms-automation
    echo '  → Set ownership to mongod user'
fi

# Clean up extracted directory
echo '  → Cleaning up temporary files...'
cd /tmp
rm -rf mongodb-mms-automation-agent-* 2>/dev/null || true

echo '✓ Agent binaries installed'
"
echo ""

# Create the agent configuration
echo "==> Creating agent configuration..."
docker exec -u root mongodb-ops-manager bash -c "
cat > /etc/mongodb-mms/automation-agent.config << 'EOFCONFIG'
mmsGroupId=${GROUP_ID}
mmsApiKey=${AGENT_API_KEY}
mmsBaseUrl=${MMS_BASE_URL}
logFile=/var/log/mongodb-mms-automation/automation-agent.log
mmsConfigBackup=/var/lib/mongodb-mms-automation/mms-cluster-config-backup.json
logLevel=INFO
maxLogFiles=10
maxLogFileSize=268435456
EOFCONFIG
"
echo "✓ Configuration created"
echo ""

# Start the agent with proper PATH
echo "==> Starting MongoDB Agent..."
AGENT_START_RESULT=$(docker exec -u root mongodb-ops-manager bash -c "
set +e  # Don't exit on error, we'll handle it
# Set proper PATH so agent can find hostname and other utilities
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Start the agent
nohup /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent \
    -f /etc/mongodb-mms/automation-agent.config \
    > /var/log/mongodb-mms-automation/agent-startup.log 2>&1 &

sleep 5

# Verify agent is running
if pgrep -f mongodb-mms-automation-agent > /dev/null 2>&1; then
    AGENT_PID=\$(pgrep -f mongodb-mms-automation-agent)
    echo \"SUCCESS:\$AGENT_PID\"
else
    echo \"FAILED\"
fi
")

if [[ "$AGENT_START_RESULT" == SUCCESS:* ]]; then
    AGENT_PID="${AGENT_START_RESULT#SUCCESS:}"
    echo "✓ Agent started successfully (PID: $AGENT_PID)"
    echo ""
    echo "Agent logs:"
    docker exec mongodb-ops-manager tail -10 /var/log/mongodb-mms-automation/agent-startup.log 2>/dev/null || echo '  (logs not available yet)'
else
    echo "⚠️  Agent may not have started. Checking logs..."
    echo ""
    echo "--- agent-startup.log ---"
    docker exec mongodb-ops-manager cat /var/log/mongodb-mms-automation/agent-startup.log 2>/dev/null || echo 'No logs available'
    echo ""
    echo "⚠️  Note: Agent might still be starting. Check status with:"
    echo "  docker exec mongodb-ops-manager pgrep -fa mongodb-mms-automation-agent"
fi

echo ""
echo "=========================================="
echo "✅ Installation Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Refresh the Meta OM UI (http://localhost:8080)"
echo "  2. The agent should appear within 30-60 seconds"
echo "  3. Monitoring and Backup should transition from 'standby' to 'active'"
echo ""
echo "To check agent logs:"
echo "  docker exec mongodb-ops-manager tail -f /var/log/mongodb-mms-automation/automation-agent.log"
echo ""
echo "To check agent status:"
echo "  docker exec mongodb-ops-manager pgrep -fa mongodb-mms-automation-agent"
echo ""
#!/bin/bash

# Setup AppDB for Primary/Customer OM
# This script sets up a MongoDB 7.0 Enterprise replica set container to serve as
# the AppDB for the primary (local bazel) OM instance, and installs the Meta OM
# automation agent inside it.
#
# What it does:
#   1. Creates Docker volumes and starts a MongoDB container
#   2. Connects the container to the Meta OM Docker network
#   3. Initializes the replica set with the Docker network IP
#   4. Reconfigures RS member hostname for Meta OM discovery
#   5. Installs and starts the Meta OM automation agent
#
# Idempotent: safe to re-run. Preserves data, restarts stopped containers,
# skips already-completed steps. Pass --fresh for a clean rebuild.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONTAINER_NAME="mongodb-ops-manager"
VOLUME_NAME="primary-om-appdb"
HOST_PORT="27018"
CONTAINER_PORT="27017"
REPLICA_SET_NAME="appdb-rs"
MONGODB_IMAGE="mongodb/mongodb-enterprise-server:7.0-ubi8"
DOCKER_NETWORK="ops-manager_main"
META_OM_BASE_URL="http://ops.om.internal:8080"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/primary-appdb-config"
CONFIG_FILE="$CONFIG_DIR/mongod.conf"

# Parse flags
FRESH=false
for arg in "$@"; do
  case $arg in
    --fresh) FRESH=true ;;
  esac
done

# ── Helper: wait for mongod to be ready ───────────────────────────────────
wait_for_mongod() {
  echo "Waiting for mongod to be ready..."
  for i in $(seq 1 12); do
    sleep 5
    if docker exec "$CONTAINER_NAME" mongosh --quiet --eval "db.adminCommand({ping:1})" 2>/dev/null | grep -q "ok"; then
      echo -e "${GREEN}✓ MongoDB is up and responding${NC}"
      return 0
    fi
    [ $i -eq 12 ] && echo -e "${RED}✗ mongod did not become ready — check: docker logs $CONTAINER_NAME${NC}" && exit 1
    echo "  Still waiting... (${i}/12)"
  done
}

# ── Helper: ensure container is on Meta OM network ────────────────────────
ensure_network() {
  if docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
    docker network connect "$DOCKER_NETWORK" "$CONTAINER_NAME" 2>/dev/null || true
    CONTAINER_IP=$(docker inspect "$CONTAINER_NAME" \
      --format "{{(index .NetworkSettings.Networks \"$DOCKER_NETWORK\").IPAddress}}")
    echo -e "${GREEN}✓ Connected to $DOCKER_NETWORK — IP: $CONTAINER_IP${NC}"
  else
    echo -e "${YELLOW}⚠ Network $DOCKER_NETWORK not found — is Meta OM (quick-start) running?${NC}"
    echo "  Skipping network connection. Run manually:"
    echo "    docker network connect $DOCKER_NETWORK $CONTAINER_NAME"
  fi
}

# ── Helper: ensure RS member uses Docker network IP ───────────────────────
ensure_rs_member_hostname() {
  if [ -z "$CONTAINER_IP" ]; then
    return
  fi
  local current_host
  current_host=$(docker exec "$CONTAINER_NAME" mongosh --quiet --eval \
    "try { print(rs.conf().members[0].host) } catch(e) { print('') }" 2>/dev/null | tr -d '[:space:]')
  local expected_host="${CONTAINER_IP}:${CONTAINER_PORT}"
  if [ "$current_host" != "$expected_host" ]; then
    echo -e "${YELLOW}Reconfiguring RS member: $current_host → $expected_host${NC}"
    docker exec "$CONTAINER_NAME" mongosh --quiet --eval "
      cfg = rs.conf();
      cfg.members[0].host = '$expected_host';
      rs.reconfig(cfg);
    " >/dev/null 2>&1
    sleep 2
    echo -e "${GREEN}✓ RS member hostname updated${NC}"
  else
    echo -e "${GREEN}✓ RS member hostname already correct: $expected_host${NC}"
  fi
}

# ── Helper: install and start Meta OM agent ───────────────────────────────
ensure_agent() {
  local agent_binary="/opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent"
  local agent_config="/etc/mongodb-mms/automation-agent.config"

  # Check if agent is already running as the correct user (mongod)
  if docker exec "$CONTAINER_NAME" pgrep -f mongodb-mms-automation-agent >/dev/null 2>&1; then
    local agent_user
    agent_user=$(docker exec "$CONTAINER_NAME" ps -o user= -p \
      "$(docker exec "$CONTAINER_NAME" pgrep -f mongodb-mms-automation-agent | head -1)" 2>/dev/null | tr -d '[:space:]')
    if [ "$agent_user" = "mongod" ]; then
      echo -e "${GREEN}✓ Agent already running (user: mongod)${NC}"
      return 0
    fi
    echo -e "${YELLOW}Agent running as '$agent_user' instead of 'mongod' — restarting...${NC}"
  fi

  # Check if agent binary is installed
  if docker exec "$CONTAINER_NAME" test -f "$agent_binary" 2>/dev/null; then
    echo -e "${GREEN}✓ Agent binary already installed${NC}"
  else
    echo "Installing Meta OM agent..."
    install_agent
  fi

  # Check if agent config exists, create/update if needed
  ensure_agent_config

  # Start the agent
  start_agent
}

install_agent() {
  # Detect the agent tarball in Meta OM container
  local agent_tarball
  agent_tarball=$(docker exec ops bash -c \
    "ls /opt/mongodb/mms/agent/automation/*aarch64.tar.gz 2>/dev/null | head -1" || echo "")
  if [ -z "$agent_tarball" ]; then
    echo -e "${RED}✗ No ARM64 agent tarball found in Meta OM container${NC}"
    echo "  Expected: /opt/mongodb/mms/agent/automation/*aarch64.tar.gz"
    exit 1
  fi
  echo "  Found agent: $(basename "$agent_tarball")"

  # Copy agent: Meta OM → host → AppDB container
  docker cp "ops:$agent_tarball" "/tmp/mongodb-agent.tar.gz"
  docker cp /tmp/mongodb-agent.tar.gz "$CONTAINER_NAME":/tmp/mongodb-agent.tar.gz

  # Install required packages and agent binaries
  # All agent dirs are owned by mongod — the agent MUST run as the same user as mongod
  docker exec -u root "$CONTAINER_NAME" bash -c "
    set -e
    yum install -y hostname procps-ng >/dev/null 2>&1 || true

    cd /tmp
    rm -rf mongodb-mms-automation-agent-* 2>/dev/null || true
    tar -xzf mongodb-agent.tar.gz

    EXTRACTED_DIR=\$(ls -d mongodb-mms-automation-agent-* 2>/dev/null | head -1)
    if [ -z \"\$EXTRACTED_DIR\" ]; then
      echo 'ERROR: Failed to find extracted agent directory'
      exit 1
    fi

    mkdir -p /opt/mongodb-mms-automation/bin
    cp -f \"\$EXTRACTED_DIR/mongodb-mms-automation-agent\" /opt/mongodb-mms-automation/bin/
    cp -f \"\$EXTRACTED_DIR/fatallogger\" /opt/mongodb-mms-automation/bin/ 2>/dev/null || true
    chmod +x /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent
    [ -f /opt/mongodb-mms-automation/bin/fatallogger ] && chmod +x /opt/mongodb-mms-automation/bin/fatallogger

    mkdir -p /etc/mongodb-mms /var/log/mongodb-mms-automation /var/lib/mongodb-mms-automation

    # Everything must be owned by mongod (same user as the mongod process)
    chown -R mongod:mongod /opt/mongodb-mms-automation
    chown -R mongod:mongod /etc/mongodb-mms
    chown -R mongod:mongod /var/log/mongodb-mms-automation
    chown -R mongod:mongod /var/lib/mongodb-mms-automation

    rm -rf /tmp/mongodb-mms-automation-agent-* /tmp/mongodb-agent.tar.gz 2>/dev/null || true
  "
  rm -f /tmp/mongodb-agent.tar.gz
  echo -e "${GREEN}✓ Agent binaries installed${NC}"
}

ensure_agent_config() {
  local agent_config="/etc/mongodb-mms/automation-agent.config"

  # Pull credentials from node1's agent config (already connected to Meta OM)
  local group_id api_key
  group_id=$(docker exec node1 grep "^mmsGroupId=" /etc/mongodb-mms/automation-agent.config 2>/dev/null | cut -d= -f2)
  api_key=$(docker exec node1 grep "^mmsApiKey=" /etc/mongodb-mms/automation-agent.config 2>/dev/null | cut -d= -f2)

  if [ -z "$group_id" ] || [ -z "$api_key" ]; then
    echo -e "${RED}✗ Could not read Meta OM credentials from node1 container${NC}"
    echo "  Is the node1 agent configured and running?"
    exit 1
  fi

  docker exec -u root "$CONTAINER_NAME" bash -c "
    cat > $agent_config << 'EOFCONFIG'
mmsGroupId=${group_id}
mmsApiKey=${api_key}
mmsBaseUrl=${META_OM_BASE_URL}
logFile=/var/log/mongodb-mms-automation/automation-agent.log
mmsConfigBackup=/var/lib/mongodb-mms-automation/mms-cluster-config-backup.json
logLevel=INFO
maxLogFiles=10
maxLogFileSize=268435456
EOFCONFIG
  "
  echo -e "${GREEN}✓ Agent config written (group: ${group_id:0:12}...)${NC}"
}

start_agent() {
  # Stop any existing agent and clean up lockfile
  docker exec -u root "$CONTAINER_NAME" bash -c "
    if command -v pkill >/dev/null 2>&1 && pgrep -f mongodb-mms-automation-agent >/dev/null 2>&1; then
      pkill -f mongodb-mms-automation-agent 2>/dev/null || true
      sleep 2
      # Force kill any survivors
      pkill -9 -f mongodb-mms-automation-agent 2>/dev/null || true
      sleep 1
    fi
    rm -f /tmp/mongodb-mms-automation.lock
  " || true

  # Ensure all agent dirs are owned by mongod (in case of prior root-owned runs)
  docker exec -u root "$CONTAINER_NAME" bash -c "
    chown -R mongod:mongod /opt/mongodb-mms-automation /etc/mongodb-mms \
      /var/log/mongodb-mms-automation /var/lib/mongodb-mms-automation 2>/dev/null || true
  "

  # Start agent as mongod user (must match the user running mongod)
  docker exec -d -u mongod "$CONTAINER_NAME" \
    /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent \
    -f /etc/mongodb-mms/automation-agent.config

  sleep 5

  if docker exec "$CONTAINER_NAME" pgrep -f mongodb-mms-automation-agent >/dev/null 2>&1; then
    local agent_user
    agent_user=$(docker exec "$CONTAINER_NAME" ps -o user= -p \
      "$(docker exec "$CONTAINER_NAME" pgrep -f mongodb-mms-automation-agent | head -1)" 2>/dev/null | tr -d '[:space:]')
    echo -e "${GREEN}✓ Agent started (user: $agent_user)${NC}"
  else
    echo -e "${RED}✗ Agent failed to start — check logs:${NC}"
    echo "  docker exec $CONTAINER_NAME tail -20 /var/log/mongodb-mms-automation/automation-agent.log"
    exit 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════

echo "=== Primary OM AppDB Setup ==="
echo ""

# ── Idempotency check ──────────────────────────────────────────────────────
if [ "$FRESH" = false ]; then
  # Case 1: container running, RS ok, on network
  if docker ps --filter "name=^${CONTAINER_NAME}$" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    RS_OK=$(docker exec "$CONTAINER_NAME" mongosh --quiet --eval \
      "try { print(rs.status().ok) } catch(e) { print(0) }" 2>/dev/null | tr -d '[:space:]')
    CONTAINER_IP=$(docker inspect "$CONTAINER_NAME" \
      --format "{{(index .NetworkSettings.Networks \"$DOCKER_NETWORK\").IPAddress}}" 2>/dev/null)
    if [ "$RS_OK" = "1" ] && [ -n "$CONTAINER_IP" ]; then
      echo -e "${GREEN}✓ AppDB already running and initialized${NC}"
      ensure_rs_member_hostname
      echo ""
      echo -e "${BLUE}Ensuring Meta OM agent...${NC}"
      ensure_agent
      echo ""
      echo -e "${GREEN}=== Done (nothing rebuilt) ===${NC}"
      echo ""
      echo -e "${YELLOW}AppDB: host.docker.internal:$HOST_PORT (replica set: $REPLICA_SET_NAME)${NC}"
      echo -e "${BLUE}Meta OM seed node: ${CONTAINER_IP}:$CONTAINER_PORT${NC}"
      exit 0
    fi
  fi

  # Case 2: volumes exist but container is stopped — restart without wiping data
  if docker volume inspect "$VOLUME_NAME" &>/dev/null; then
    echo -e "${YELLOW}Existing AppDB data found — restarting container without wiping volumes${NC}"
    echo -e "${YELLOW}(Pass --fresh to do a clean rebuild and lose all data)${NC}"
    echo ""

    if docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
      docker start "$CONTAINER_NAME"
    else
      mkdir -p "$CONFIG_DIR"
      cat > "$CONFIG_FILE" << EOF
# mongod.conf - MongoDB configuration file

storage:
  dbPath: /data/db

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 0.0.0.0

replication:
  replSetName: $REPLICA_SET_NAME
EOF
      docker run -d \
        --name "$CONTAINER_NAME" \
        -p "$HOST_PORT":"$CONTAINER_PORT" \
        -v "$VOLUME_NAME":/data/db \
        -v "${VOLUME_NAME}-log":/var/log/mongodb \
        -v "$CONFIG_FILE":/etc/mongodb/mongod.conf:ro \
        "$MONGODB_IMAGE" \
        --config /etc/mongodb/mongod.conf
    fi

    wait_for_mongod
    ensure_network
    ensure_rs_member_hostname
    echo ""
    echo -e "${BLUE}Ensuring Meta OM agent...${NC}"
    ensure_agent
    echo ""
    echo -e "${GREEN}=== AppDB restarted (data preserved) ===${NC}"
    echo ""
    echo -e "${YELLOW}AppDB: host.docker.internal:$HOST_PORT (replica set: $REPLICA_SET_NAME)${NC}"
    echo -e "${BLUE}Meta OM seed node: ${CONTAINER_IP:-<run: docker inspect $CONTAINER_NAME>}:$CONTAINER_PORT${NC}"
    exit 0
  fi
fi

if [ "$FRESH" = true ]; then
  echo -e "${RED}⚠ --fresh passed: all existing AppDB data will be destroyed${NC}"
  echo ""
fi

# ── Fresh setup ───────────────────────────────────────────────────────────

# Step 1: Pull image
echo -e "${BLUE}1. Pulling MongoDB Enterprise 7.0 image${NC}"
echo "------------------------------"
docker pull $MONGODB_IMAGE
echo -e "${GREEN}✓ Image ready${NC}"
echo ""

# Step 2: Clean up any existing containers and volumes
echo -e "${BLUE}2. Cleaning up existing containers and volumes${NC}"
echo "------------------------------"
docker stop $CONTAINER_NAME 2>/dev/null && echo "Stopped $CONTAINER_NAME" || true
docker rm $CONTAINER_NAME 2>/dev/null && echo "Removed $CONTAINER_NAME" || true
docker volume rm $VOLUME_NAME 2>/dev/null && echo "Removed volume $VOLUME_NAME" || true
docker volume rm ${VOLUME_NAME}-log 2>/dev/null && echo "Removed volume ${VOLUME_NAME}-log" || true
echo -e "${GREEN}✓ Cleanup done${NC}"
echo ""

# Step 3: Create volumes
echo -e "${BLUE}3. Creating Docker volumes${NC}"
echo "------------------------------"
docker volume create $VOLUME_NAME
docker volume create ${VOLUME_NAME}-log
echo -e "${GREEN}✓ Volumes ready${NC}"
echo ""

# Step 4: Write mongod config file
echo -e "${BLUE}4. Writing mongod config file${NC}"
echo "------------------------------"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" << EOF
# mongod.conf - MongoDB configuration file

# Where to store data
storage:
  dbPath: /data/db

# Where to write logging data
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

# Network interfaces
net:
  port: 27017
  bindIp: 0.0.0.0

# Replication
replication:
  replSetName: $REPLICA_SET_NAME
EOF
echo -e "${GREEN}✓ Config file written${NC}"
echo ""

# Step 5: Start the MongoDB container
echo -e "${BLUE}5. Starting MongoDB container${NC}"
echo "------------------------------"
docker run --rm -u root \
  -v ${VOLUME_NAME}-log:/var/log/mongodb \
  $MONGODB_IMAGE \
  bash -c "mkdir -p /var/log/mongodb && chown -R mongod:mongod /var/log/mongodb" 2>/dev/null || \
docker run --rm -u root \
  -v ${VOLUME_NAME}-log:/var/log/mongodb \
  alpine sh -c "mkdir -p /var/log/mongodb && chown -R 999:999 /var/log/mongodb"

docker run -d \
  --name $CONTAINER_NAME \
  -p $HOST_PORT:$CONTAINER_PORT \
  -v $VOLUME_NAME:/data/db \
  -v ${VOLUME_NAME}-log:/var/log/mongodb \
  -v "$CONFIG_FILE":/etc/mongodb/mongod.conf:ro \
  $MONGODB_IMAGE \
  --config /etc/mongodb/mongod.conf

wait_for_mongod
echo ""

# Step 6: Connect to Meta OM network
echo -e "${BLUE}6. Connecting to Meta OM Docker network: $DOCKER_NETWORK${NC}"
echo "------------------------------"
ensure_network
echo ""

# Step 7: Initialize the replica set (use Docker network IP for Meta OM discovery)
echo -e "${BLUE}7. Initializing replica set: $REPLICA_SET_NAME${NC}"
echo "------------------------------"
sleep 5

RS_HOST="${CONTAINER_IP:-host.docker.internal:$HOST_PORT}"
[ -n "$CONTAINER_IP" ] && RS_HOST="${CONTAINER_IP}:${CONTAINER_PORT}"

RS_RESULT=$(docker exec $CONTAINER_NAME mongosh --quiet --eval "
try {
  const r = rs.initiate({_id: '$REPLICA_SET_NAME', members: [{_id: 0, host: '$RS_HOST'}]});
  print(JSON.stringify(r));
} catch(e) {
  print(JSON.stringify({ok: 0, errmsg: e.message}));
}" 2>&1)
echo "$RS_RESULT"
if echo "$RS_RESULT" | grep -q '"ok":1'; then
  echo -e "${GREEN}✓ Replica set initialized (member: $RS_HOST)${NC}"
else
  echo -e "${RED}✗ rs.initiate failed${NC}"
  exit 1
fi

sleep 3

echo ""
echo "Replica set status:"
docker exec $CONTAINER_NAME mongosh --quiet --eval \
  "rs.status().members.map(m => ({name: m.name, state: m.stateStr}))"
echo ""

# Step 8: Install and start Meta OM agent
echo -e "${BLUE}8. Installing Meta OM agent${NC}"
echo "------------------------------"
ensure_agent
echo ""

echo -e "${GREEN}=== AppDB setup complete ===${NC}"
echo ""
echo -e "${YELLOW}AppDB: host.docker.internal:$HOST_PORT (replica set: $REPLICA_SET_NAME)${NC}"
echo -e "${BLUE}Meta OM seed node: ${CONTAINER_IP:-<check: docker inspect $CONTAINER_NAME>}:$CONTAINER_PORT${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Run primary OM:  bazel run --server_env=hosted //server:mms"
echo "  2. In Meta OM UI (http://localhost:8080) → Add Existing Deployment → seed: ${CONTAINER_IP}:$CONTAINER_PORT"

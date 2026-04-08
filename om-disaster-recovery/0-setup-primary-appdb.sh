#!/bin/bash

# Setup AppDB for Primary/Customer OM
# This script sets up a MongoDB 7.0 Enterprise replica set container to serve as
# the AppDB for the primary (local bazel) OM instance.
#
# What it does:
#   1. Creates a Docker volume for AppDB data
#   2. Starts a temporary container to write the mongod config file
#   3. Starts the final MongoDB container using that config file
#   4. Connects the container to the Meta OM Docker network
#   5. Initializes the replica set with host.docker.internal:27018

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/primary-appdb-config"
CONFIG_FILE="$CONFIG_DIR/mongod.conf"

echo "=== Primary OM AppDB Setup ==="
echo ""

# Step 1: Pull image
echo -e "${BLUE}1. Pulling MongoDB Enterprise 7.0 image${NC}"
echo "------------------------------"
docker pull $MONGODB_IMAGE
echo -e "${GREEN}✓ Image ready${NC}"
echo ""

# Step 2: Clean up any existing containers and volumes (fresh start)
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

# Step 4: Write mongod config file to host (bind-mounted into the container)
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

echo -e "${GREEN}✓ Config file written to $CONFIG_FILE${NC}"
echo ""

# Step 5: Start the final container with the config file bind-mounted from host
echo -e "${BLUE}5. Starting MongoDB container with config file${NC}"
echo "------------------------------"
# Create the log directory with correct permissions before starting mongod
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

echo "Waiting for mongod to be ready..."
for i in $(seq 1 12); do
  sleep 5
  if ! docker ps --filter "name=^${CONTAINER_NAME}$" --filter "status=running" --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
    echo -e "${RED}✗ Container exited — check: docker logs $CONTAINER_NAME${NC}"
    docker logs $CONTAINER_NAME 2>&1 | tail -10
    exit 1
  fi
  if docker exec $CONTAINER_NAME mongosh --quiet --eval "db.adminCommand({ping:1})" 2>/dev/null | grep -q "ok"; then
    echo -e "${GREEN}✓ MongoDB is up and responding${NC}"
    break
  fi
  if [ $i -eq 12 ]; then
    echo -e "${RED}✗ mongod did not become ready after 60s — check: docker logs $CONTAINER_NAME${NC}"
    exit 1
  fi
  echo "  Still waiting... (${i}/12)"
done
echo ""

# Step 6: Connect to Meta OM network
echo -e "${BLUE}6. Connecting to Meta OM Docker network: $DOCKER_NETWORK${NC}"
echo "------------------------------"
if docker network inspect $DOCKER_NETWORK &>/dev/null; then
  docker network connect $DOCKER_NETWORK $CONTAINER_NAME 2>/dev/null || true
  CONTAINER_IP=$(docker inspect $CONTAINER_NAME --format "{{(index .NetworkSettings.Networks \"$DOCKER_NETWORK\").IPAddress}}")
  echo -e "${GREEN}✓ Connected — IP on $DOCKER_NETWORK: $CONTAINER_IP${NC}"
else
  echo -e "${YELLOW}⚠ Network $DOCKER_NETWORK not found — is Meta OM (quick-start) running?${NC}"
  echo "  Skipping network connection. Run manually:"
  echo "    docker network connect $DOCKER_NETWORK $CONTAINER_NAME"
fi
echo ""

# Step 7: Initialize the replica set
echo -e "${BLUE}7. Initializing replica set: $REPLICA_SET_NAME${NC}"
echo "------------------------------"
echo "Waiting for mongod to be ready..."
sleep 5

RS_RESULT=$(docker exec $CONTAINER_NAME mongosh --quiet --eval "
try {
  const r = rs.initiate({_id: '$REPLICA_SET_NAME', members: [{_id: 0, host: 'host.docker.internal:$HOST_PORT'}]});
  print(JSON.stringify(r));
} catch(e) {
  print(JSON.stringify({ok: 0, errmsg: e.message}));
}" 2>&1)
echo "$RS_RESULT"
if echo "$RS_RESULT" | grep -q '"ok":1\|AlreadyInitialized'; then
  echo -e "${GREEN}✓ Replica set initialized${NC}"
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
echo -e "${GREEN}=== AppDB setup complete ===${NC}"
echo ""
echo -e "${YELLOW}AppDB is running at: host.docker.internal:$HOST_PORT (replica set: $REPLICA_SET_NAME)${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Run primary OM:  bazel run --server_env=hosted //server:mms"
echo "  2. Connect to Meta OM UI (http://localhost:8080) to back up this AppDB"
echo "  3. When ready to test DR restore, run: ./om-disaster-recovery scripts"

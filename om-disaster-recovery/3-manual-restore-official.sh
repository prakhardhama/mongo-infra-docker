#!/bin/bash

# Disaster Recovery PoC - Phase 3: Manual Restore (Official MongoDB Process)
# Based on: https://www.mongodb.com/docs/ops-manager/current/tutorial/restore-replica-set/#manual-restore
#
# ⚠️ CRITICAL: This script uses a FULL snapshot (Incremental: No)
# - Incremental snapshots will NOT work with this method
# - Always verify snapshot type in Meta OM UI before downloading
# - FULL snapshots are typically larger (150MB+) vs incremental (~125MB)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SNAPSHOT_DIR="/tmp/om-restore-old-snapshot/appdb-rs-1773036152-69ae9a3ce6fd443e8b641ab8"
CONTAINER_NAME="mongodb-ops-manager"
CONTAINER_HOSTNAME="75c8593e08b3"  # CRITICAL: Must match original hostname for agent reconnection
VOLUME_NAME="primary-om-appdb"
EPHEMERAL_PORT="27018"
REPLICA_SET_NAME="appdb-rs"
MONGODB_IMAGE="mongodb/mongodb-enterprise-server:7.0-ubi8"
DOCKER_NETWORK="ops-manager_main"  # Required for agent to connect to Meta OM

echo "=== Manual Restore Following Official MongoDB Documentation ==="
echo ""
echo -e "${YELLOW}⚠️  IMPORTANT: Ensure you're using a FULL snapshot (Incremental: No)${NC}"
echo -e "${YELLOW}   Incremental snapshots will fail with WiredTiger errors${NC}"
echo ""
echo "Snapshot: $SNAPSHOT_DIR"
echo "Target: $CONTAINER_NAME on port $EPHEMERAL_PORT"
echo ""

# Step 1: Verify snapshot exists
echo "1. Verifying snapshot files"
echo "------------------------------"
if [ ! -d "$SNAPSHOT_DIR" ]; then
    echo -e "${RED}✗ Snapshot directory not found: $SNAPSHOT_DIR${NC}"
    exit 1
fi

FILE_COUNT=$(ls -1 "$SNAPSHOT_DIR" | wc -l)
echo -e "${GREEN}✓ Found $FILE_COUNT files in snapshot${NC}"
echo ""

# Step 2: Remove existing container if it exists
echo "2. Removing existing container (if any)"
echo "------------------------------"
docker stop $CONTAINER_NAME 2>/dev/null || true
docker rm $CONTAINER_NAME 2>/dev/null || true
echo -e "${GREEN}✓ Container removed${NC}"
echo ""

# Step 3: Create volume and clear data directory
echo "3. Creating volume and clearing data directory"
echo "------------------------------"
docker volume create $VOLUME_NAME 2>/dev/null || true
docker run --rm -v $VOLUME_NAME:/data alpine sh -c "rm -rf /data/*"
echo -e "${GREEN}✓ Volume created and cleared${NC}"
echo ""

# Step 4: Copy snapshot files to volume
echo "4. Copying snapshot files to data directory"
echo "------------------------------"
docker run --rm \
    -v $VOLUME_NAME:/data \
    -v $SNAPSHOT_DIR:/snapshot:ro \
    alpine sh -c "
    cp -r /snapshot/* /data/ && \
    chown -R 1000:1000 /data && \
    ls -la /data/ | head -20
"
echo -e "${GREEN}✓ Snapshot files copied${NC}"
echo ""

# Step 5: Create and start MongoDB container
echo "5. Creating MongoDB container with original hostname"
echo "------------------------------"
echo "Container configuration:"
echo "  - Name: $CONTAINER_NAME"
echo "  - Hostname: $CONTAINER_HOSTNAME (CRITICAL for agent reconnection!)"
echo "  - Port: $EPHEMERAL_PORT:27017"
echo "  - Volume: $VOLUME_NAME"
echo "  - Network: $DOCKER_NETWORK"
echo "  - Replica Set: $REPLICA_SET_NAME"
echo ""

docker run -d \
  --name $CONTAINER_NAME \
  --hostname $CONTAINER_HOSTNAME \
  -p $EPHEMERAL_PORT:27017 \
  -v $VOLUME_NAME:/data/db \
  --network $DOCKER_NETWORK \
  $MONGODB_IMAGE \
  --replSet $REPLICA_SET_NAME --bind_ip_all

echo -e "${GREEN}✓ Container created and started${NC}"
echo ""

# Wait for MongoDB to start
echo "Waiting for MongoDB to start..."
sleep 10

# Check if MongoDB started successfully
if docker logs $CONTAINER_NAME --tail 50 | grep -q "Waiting for connections"; then
    echo -e "${GREEN}✓ MongoDB started successfully${NC}"
else
    echo -e "${YELLOW}⚠ MongoDB may still be starting, checking logs...${NC}"
    docker logs $CONTAINER_NAME --tail 30
fi
echo ""

# Step 6: Fix replica set configuration
echo "6. Fixing replica set configuration"
echo "------------------------------"
echo "Reconfiguring replica set to use hostname: $CONTAINER_HOSTNAME:27017"
sleep 5

mongosh "mongodb://localhost:$EPHEMERAL_PORT/?directConnection=true" --quiet --eval "
rs.reconfig({
    _id: '$REPLICA_SET_NAME',
    members: [{_id: 0, host: '$CONTAINER_HOSTNAME:27017'}]
}, {force: true});
"

echo -e "${GREEN}✓ Replica set reconfigured${NC}"
echo ""

# Step 7: Verify restoration
echo "7. Verifying restoration"
echo "------------------------------"
sleep 5

# Try to connect and check databases
if mongosh "mongodb://localhost:$EPHEMERAL_PORT/?directConnection=true" --quiet --eval "db.adminCommand({ping: 1})" 2>/dev/null; then
    echo -e "${GREEN}✓ MongoDB is accessible${NC}"

    echo ""
    echo "Databases found:"
    DB_COUNT=$(mongosh "mongodb://localhost:$EPHEMERAL_PORT/?directConnection=true" --quiet --eval "
        db.adminCommand('listDatabases').databases.forEach(function(db) {
            print('  - ' + db.name + ' (' + (db.sizeOnDisk / 1024 / 1024).toFixed(2) + ' MB)');
        });
        print('Total: ' + db.adminCommand('listDatabases').databases.length + ' databases');
    ")
    echo "$DB_COUNT"

    echo ""
    echo "Replica set status:"
    mongosh "mongodb://localhost:$EPHEMERAL_PORT/?directConnection=true" --quiet --eval "
        try {
            var status = rs.status();
            print('  Replica Set: ' + status.set);
            print('  State: ' + (status.myState === 1 ? 'PRIMARY' : status.myState === 2 ? 'SECONDARY' : 'OTHER (' + status.myState + ')'));
            print('  Members: ' + status.members.length);
            status.members.forEach(function(m) {
                print('    - ' + m.name + ' (' + m.stateStr + ')');
            });
        } catch(e) {
            print('  Error: ' + e.message);
        }
    "
else
    echo -e "${RED}✗ Cannot connect to MongoDB${NC}"
    echo "Checking logs:"
    docker logs $CONTAINER_NAME --tail 50
    exit 1
fi

echo ""
echo "=== Manual Restore Complete ==="
echo ""
echo -e "${GREEN}✓ MongoDB restored successfully!${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Next steps for complete recovery:${NC}"
echo ""
echo "  1. Reinstall Monitoring and Backup agents:"
echo "     cd /Users/prakhar.dhama/mongo-infra-docker"
echo "     ./om-docker/meta-om-primary-appdb-agent-installation.sh"
echo ""
echo "  2. Verify agents appear in Meta OM UI:"
echo "     - Go to: http://localhost:8080"
echo "     - Check: Servers tab → $CONTAINER_HOSTNAME"
echo "     - Verify: Monitoring and Backup agents are green"
echo ""
echo "  3. Verify backup resumes:"
echo "     - Go to: Backup tab"
echo "     - Check: appdb-rs backup status"
echo ""
echo "  4. Run verification script:"
echo "     ./om-disaster-recovery/4-verify-recovery.sh"
echo ""


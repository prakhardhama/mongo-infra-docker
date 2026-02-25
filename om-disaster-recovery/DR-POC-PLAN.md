# Ops Manager Disaster Recovery PoC Plan

## Objective
Demonstrate disaster recovery for Primary Ops Manager by restoring its appDB from backups managed by Meta Ops Manager.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Meta Ops Manager                         │
│                    (Docker - Port 8080)                      │
│                                                              │
│  - Manages Primary OM's appDB replica set                   │
│  - Takes backups of Primary OM's appDB                      │
│  - Stores backups in S3/filesystem                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Manages & Backs Up
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              Primary OM's appDB Replica Set                  │
│                  (Docker - Port 27171)                       │
│                                                              │
│  - Single node replica set: node1.om.internal:27017         │
│  - Mapped to host: localhost:27171                          │
│  - Port forwarded: localhost:27017 → localhost:27171        │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Used By
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  Primary Ops Manager                         │
│                   (Bazel - Port 8081)                        │
│                                                              │
│  - Connects to appDB via localhost:27171                    │
│  - Manages customer MongoDB deployments                     │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

### 1. Current Setup Verification
- [ ] Meta OM is running in Docker (port 8080)
- [ ] Primary OM's appDB replica set is deployed and running (port 27171)
- [ ] Port forwarder is running (27017 → 27171)
- [ ] Primary OM can start and connect to appDB
- [ ] Meta OM has backup configured for Primary OM's appDB

### 2. Backup Configuration in Meta OM
- [ ] Backup daemon is enabled
- [ ] Backup target configured (S3 or filesystem)
- [ ] Primary OM's appDB replica set is added to backup
- [ ] At least one successful backup snapshot exists

## PoC Phases

### Phase 1: Setup & Baseline (Pre-Disaster)

**Goal**: Establish a working baseline and verify backups

1. **Start all services**
   ```bash
   # Start Meta OM (Docker)
   cd /Users/prakhar.dhama/mongo-infra-docker/ops-manager
   docker-compose up -d
   
   # Start port forwarder
   cd /Users/prakhar.dhama/mongo-infra-docker
   ./scripts/start-port-forward.sh
   
   # Start Primary OM (Bazel)
   cd /Users/prakhar.dhama/ops-manager
   bazel run --server_env=hosted //server:mms
   ```

2. **Create test data in Primary OM**
   - Create a user account
   - Create a project
   - Add some configuration
   - Document the state (screenshot/notes)

3. **Verify backup is running**
   - Check Meta OM UI → Backup tab
   - Verify Primary OM's appDB is being backed up
   - Wait for at least one snapshot to complete
   - Note the snapshot ID and timestamp

4. **Document baseline state**
   - Primary OM version
   - appDB replica set name
   - Backup snapshot ID
   - Test data created

### Phase 2: Disaster Simulation

**Goal**: Simulate complete loss of Primary OM's appDB

1. **Stop Primary OM**
   ```bash
   # Stop the Bazel process (Ctrl+C or kill)
   ```

2. **Destroy the appDB**
   ```bash
   # Option A: Drop all databases (simulates corruption)
   mongosh "mongodb://localhost:27171/" --eval "
     db.adminCommand({listDatabases: 1}).databases.forEach(function(d) {
       if (d.name != 'admin' && d.name != 'local' && d.name != 'config') {
         db.getSiblingDB(d.name).dropDatabase();
       }
     });
   "
   
   # Option B: Stop and remove data directory (simulates hardware failure)
   # This would require stopping the Docker container and removing volumes
   ```

3. **Verify disaster**
   ```bash
   # Try to start Primary OM - it should fail or show empty state
   ```

### Phase 3: Recovery

**Goal**: Restore Primary OM's appDB from Meta OM backup

1. **Identify the backup snapshot to restore**
   - Log into Meta OM UI
   - Navigate to Backup → Snapshots
   - Identify the snapshot taken before disaster
   - Note the snapshot ID

2. **Initiate restore from Meta OM**
   - In Meta OM UI, go to the backup for Primary OM's appDB
   - Click "Restore"
   - Choose the snapshot
   - Select restore method:
     - **Automated Restore**: Meta OM restores directly to the replica set
     - **Download Restore**: Download snapshot and restore manually

3. **Monitor restore progress**
   - Watch restore job in Meta OM
   - Verify data is being written back to appDB

4. **Verify appDB is restored**
   ```bash
   # Check databases are back
   mongosh "mongodb://localhost:27171/" --eval "db.adminCommand({listDatabases: 1})"
   
   # Check for your test data
   mongosh "mongodb://localhost:27171/mmsdbconfig" --eval "db.users.count()"
   ```

### Phase 4: Verification

**Goal**: Verify Primary OM is fully functional after recovery

1. **Start Primary OM**
   ```bash
   cd /Users/prakhar.dhama/ops-manager
   bazel run --server_env=hosted //server:mms
   ```

2. **Verify Primary OM functionality**
   - [ ] Primary OM starts without errors
   - [ ] Can log in with previous credentials
   - [ ] Projects are visible
   - [ ] Configuration is intact
   - [ ] Can create new projects/users
   - [ ] Can manage deployments

3. **Compare with baseline**
   - Verify test data matches pre-disaster state
   - Check timestamps to confirm data is from backup

## Success Criteria

- [ ] Primary OM's appDB was completely destroyed
- [ ] Restore completed successfully from Meta OM backup
- [ ] Primary OM is fully functional after restore
- [ ] All pre-disaster data is recovered
- [ ] Recovery time is documented
- [ ] Process is repeatable

## Rollback Plan

If recovery fails:
1. Stop Primary OM
2. Deploy a fresh appDB replica set
3. Let Primary OM initialize a new appDB
4. Reconfigure from scratch

## Next Steps

After successful PoC:
1. Document the recovery procedure
2. Create automation scripts
3. Define RTO/RPO requirements
4. Establish backup retention policies
5. Create runbook for production DR


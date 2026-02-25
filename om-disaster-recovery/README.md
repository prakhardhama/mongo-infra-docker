# Ops Manager Disaster Recovery PoC

This directory contains scripts and documentation for demonstrating disaster recovery of Primary Ops Manager's appDB using backups managed by Meta Ops Manager.

## Overview

**Scenario**: Primary Ops Manager's application database (appDB) is completely destroyed, and we need to restore it from backups taken by Meta Ops Manager.

**Goal**: Prove that we can recover Primary OM to a fully functional state using Meta OM's backup system.

## Architecture

```
Meta OM (Docker)
    ↓ manages & backs up
Primary OM's appDB (Docker - port 27171)
    ↓ used by
Primary OM (Bazel - port 8081)
```

## Files

- **DR-POC-PLAN.md** - Comprehensive disaster recovery plan with detailed phases
- **1-verify-setup.sh** - Verify all components are running and backups are configured
- **2-simulate-disaster.sh** - Safely simulate appDB failure
- **3-restore-from-backup.sh** - Guide for restoring from Meta OM backup
- **4-verify-recovery.sh** - Verify Primary OM is fully functional after recovery

## Quick Start

### Prerequisites

1. Meta OM running in Docker (port 8080)
2. Primary OM's appDB replica set deployed and running (port 27171)
3. Port forwarder running (27017 → 27171)
4. Meta OM has backup configured for Primary OM's appDB
5. At least one backup snapshot exists

### Running the PoC

Execute the scripts in order:

```bash
cd /Users/prakhar.dhama/mongo-infra-docker/disaster-recovery

# Phase 1: Verify setup
chmod +x *.sh
./1-verify-setup.sh

# Phase 2: Simulate disaster (destroys appDB!)
./2-simulate-disaster.sh

# Phase 3: Restore from backup (follow UI instructions)
./3-restore-from-backup.sh

# Phase 4: Verify recovery
./4-verify-recovery.sh
```

## Detailed Steps

### Phase 1: Setup & Baseline

1. Run `./1-verify-setup.sh` to check:
   - Meta OM is running
   - Primary OM's appDB is accessible
   - Port forwarder is active
   - Replica set is configured correctly

2. Create test data in Primary OM:
   - Create a user account
   - Create a project
   - Add some configuration

3. Verify backup in Meta OM:
   - Open http://localhost:8080
   - Go to Deployment > Backup
   - Verify Primary OM's appDB is being backed up
   - Wait for at least one snapshot to complete

### Phase 2: Disaster Simulation

1. Run `./2-simulate-disaster.sh`
2. Choose disaster type:
   - **Option 1**: Drop databases (permanent)
   - **Option 2**: Rename databases (can be rolled back)
3. Verify Primary OM cannot function

### Phase 3: Recovery

1. Run `./3-restore-from-backup.sh`
2. Follow the guided steps to:
   - Access Meta OM UI
   - Find the correct backup snapshot
   - Initiate restore
   - Monitor restore progress
3. Verify databases are restored

### Phase 4: Verification

1. Run `./4-verify-recovery.sh`
2. Complete manual verification steps:
   - Start Primary OM
   - Log in and verify functionality
   - Check that all data is recovered
3. Review the verification summary

## Success Criteria

- [ ] Primary OM's appDB was completely destroyed
- [ ] Restore completed successfully from Meta OM backup
- [ ] Primary OM starts without errors
- [ ] All pre-disaster data is recovered
- [ ] Primary OM is fully functional
- [ ] Recovery time is documented

## Troubleshooting

### Backup not configured in Meta OM

1. Log into Meta OM (http://localhost:8080)
2. Go to Deployment > Backup
3. Click "Start Backup System"
4. Add Primary OM's appDB replica set
5. Configure backup storage (S3 or filesystem)
6. Wait for first snapshot

### Restore fails

1. Check Meta OM logs for errors
2. Verify backup snapshot is complete
3. Ensure target replica set is accessible
4. Try manual restore using mongorestore

### Primary OM won't start after restore

1. Check Primary OM logs
2. Verify all required databases are restored
3. Check database permissions
4. Verify replica set configuration

## Rollback Plan

If recovery fails and you need to start over:

```bash
# Option 1: Restore renamed databases (if using disaster type 2)
mongosh "mongodb://localhost:27171/" --eval "
  db.adminCommand({listDatabases: 1}).databases
    .filter(d => d.name.includes('_destroyed_'))
    .forEach(d => {
      var originalName = d.name.split('_destroyed_')[0];
      print('Restoring: ' + d.name + ' -> ' + originalName);
      db.getSiblingDB(d.name).copyDatabase(d.name, originalName);
      db.getSiblingDB(d.name).dropDatabase();
    });
"

# Option 2: Deploy fresh appDB and reinitialize Primary OM
# (This loses all data but gets you back to a working state)
```

## Next Steps After Successful PoC

1. **Document findings**:
   - Recovery Time Objective (RTO) achieved
   - Recovery Point Objective (RPO) achieved
   - Any issues encountered

2. **Improve automation**:
   - Create fully automated restore script
   - Add monitoring and alerting
   - Implement automated testing

3. **Create production runbook**:
   - Step-by-step recovery procedure
   - Contact information
   - Escalation paths
   - Communication templates

4. **Establish policies**:
   - Backup retention (how long to keep snapshots)
   - Backup frequency (how often to take snapshots)
   - Testing schedule (how often to test DR)

## Additional Resources

- [Ops Manager Backup Documentation](https://www.mongodb.com/docs/ops-manager/current/tutorial/nav/backup-use/)
- [MongoDB Disaster Recovery Best Practices](https://www.mongodb.com/docs/manual/core/backups/)
- Main setup documentation: `/Users/prakhar.dhama/mongo-infra-docker/scripts/PORT-FORWARD-README.md`


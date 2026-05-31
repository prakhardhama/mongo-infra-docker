# OM Backup Phase 1 — Why this matters

_Demonstrating the data-loss scenario this feature prevents._

## TL;DR

In a Meta-OM-backs-Primary-OM topology, rolling back the Primary OM's
appdb to a state from before a customer added a shard would, **without
this feature**, cause the agent to stop the new shard's mongods on its
next poll. Any chunks the balancer had migrated to that shard would
become **unreachable through the mongos** — effective data loss until
the shard's processes are restarted by hand and OM's automation config
is rebuilt. **OM Backup Phase 1 closes this gap** by detecting the
appdb regression, putting the group into restoration mode, and merging
the agent's cached (newer) automation config back into the published
config so the new shard stays managed.

---

## The problem in one paragraph

Primary OM stores its automation config — the source of truth for which
processes are part of which replica set / sharded cluster — in its
appdb. Customers running Meta-OM-backs-Primary-OM topologies routinely
back up that appdb. If they restore the appdb from a snapshot taken
**before** a deployment change (e.g. adding a shard, adding a
replica-set member, changing process versions), the rolled-back appdb
no longer "knows" about that change. On the next poll, the agent
receives the older config, treats the now-unknown processes as ones it
should disable, and **stops them**. For replica-set members this is
operational drift. **For sharded clusters this is data loss** — any
data the balancer migrated to a new shard lives only on that shard, so
when the shard's mongods are stopped, the chunks become invisible to
the mongos.

## Why sharding makes the risk concrete (not just operational drift)

| Scenario | Data shape | What happens if the new processes are stopped |
|---|---|---|
| New replica-set member added | Data is replicated across all members | Other members still have everything → no loss |
| **New shard added + chunks migrated** | **Migrated chunks live ONLY on the new shard** | **Customer's mongos can't reach the data → effective loss** |
| New process version | Same data, new binary | Process can't run with the rolled-back binary version → operational drift |
| Index added | Index lives on the data nodes | Index queries degraded → operational impact |

The sharded case is the only one where **rolling back the appdb causes
data on the customer's deployment to become inaccessible**. That's why
this is the case we demonstrate.

## What OM Backup Phase 1 does

Three coordinated changes ship together:

1. **Regression detection.** When the agent sends `cv=<n>` (its cached
   config version) and OM's published config is at a lower version,
   OM declares the group is in restoration mode and emits a banner:

   > **Restoration Mode Active** · Reason: PITR_RESTORE · Agent config
   > version: N+k · DB config version: N

2. **Reconciliation.** OM asks the agent to upload its cached config,
   merges it into the published config, and bumps the published
   version to match. The "lost" processes (e.g. the new shard) are
   restored to OM's view before the agent's next poll has a chance to
   shut them down.

3. **Pre-exit snapshot enqueue.** Before exiting restoration mode, OM
   queues an on-demand snapshot for every RS and sharded cluster in
   the group so there's a known-coherent backup point taken
   immediately after the reconciliation finished.

Net effect for the customer: **a) the new shard's mongods are not
stopped, b) the chunks remain reachable, c) there's a fresh snapshot
on the post-recovery state**.

---

## End-to-end demonstration

### Setup

- **Meta OM**: backs up Primary OM's appdb (`appdb-rs` container,
  port 27018).
- **Primary OM**: manages a sharded deployment `poShardClust` with
  2 shards (`poShard_0`, `poShard_1`), a config server replica set,
  and a mongos at `M-FNVDKKWYJR:27066`.
- `mms.featureFlag.automation.restorationMode=enabled` on Primary OM
  (the default in v8.0.23 once the launch flips this on).
- `OmBackupFeatureFlag=true` on the agent (default in the v8.0.23
  agent build).

### Steps

1. **Baseline appdb snapshot.** In Meta OM UI → Continuous Backup →
   `appdb-rs` → ⋮ → **Take Snapshot Now**. Note the snapshot ID and
   timestamp `T_baseline`.

2. **Create a sharded collection and populate it.** From the customer
   mongos:

   ```js
   // Connect via the customer mongos
   //   mongosh "mongodb://localhost:27066"
   sh.enableSharding("demo");
   db.demo.createIndex({sk: "hashed"});
   sh.shardCollection("demo.docs", {sk: "hashed"});

   // ~50,000 docs × ~200 bytes ≈ 10 MB so the balancer has work
   const bulk = [];
   for (let i = 0; i < 50000; i++) bulk.push({insertOne:{document:{sk: i, payload: "x".repeat(200)}}});
   db.demo.docs.bulkWrite(bulk, {ordered: false});

   sh.status();   // confirm chunks exist on poShard_0 + poShard_1
   ```

3. **Add `poShard_2`.** In Primary OM UI → Deployment → poShardClust →
   **MODIFY** → **Add Shard** → 3-member replica set (members on
   ports `27067/27068/27069` or whatever the next free triple is) →
   Review & Deploy. Wait for the deploy to complete and the new
   processes to show "active" in the deployment view.

4. **Force chunk migration to poShard_2.** Balancer may take a while
   to choose to migrate; we force at least one chunk so the demo is
   deterministic:

   ```js
   // From the customer mongos
   const targetChunk = db.config.chunks.findOne({shard: {$in: ["poShard_0","poShard_1"]}});
   db.adminCommand({moveChunk: "demo.docs", find: {sk: targetChunk.min.sk}, to: "poShard_2"});
   sh.status();   // confirm at least one chunk is on poShard_2
   ```

   Record the document count on `poShard_2` directly (so we can prove
   later that data was actually moved):

   ```js
   db.demo.docs.aggregate([{$collStats: {storageStats: {}}}]);
   // OR: read via a connection to poShard_2's primary mongod
   ```

5. **Roll back Primary OM's appdb to `T_baseline`.** In Meta OM UI →
   Continuous Backup → `appdb-rs` → ⋮ → **Restore** → pick
   `T_baseline` snapshot → Automated Restore. This regresses the
   appdb to a state where `poShard_2` doesn't exist in the
   automation config.

6. **Observe the restoration-mode chain.** Within ~30–60 seconds of
   the appdb restore completing, the Primary OM UI banner should
   appear:

   > **Restoration Mode Active** · Reason: PITR_RESTORE · Agent config
   > version: N+k · DB config version: N

   Watch the OM log (see Appendix B) for the reconciliation chain.
   Within another ~30 seconds, the banner clears.

7. **Verify the data is still reachable.** From the customer mongos
   AFTER restoration mode exits:

   ```js
   db.demo.docs.countDocuments();      // expect 50000 — every chunk reachable
   sh.status();                        // expect poShard_2 still listed with chunks
   ```

### What you should see (success criteria)

| What | Expected |
|---|---|
| Restoration mode banner appears | ✅ Within ~60s of appdb restore completing |
| Reconciliation chain in OM log | ✅ `ReconciliationOrchestrator` → `CONFIG_UPLOAD AgentJob` → `ReconciliationConfigSvc.validateAndPersist` → `GroupDao.tryClearRestorationMode` → `RestorationModeSvc.exitRestorationMode` |
| Restoration mode banner clears | ✅ Within ~30s of reconciliation starting |
| `poShard_2` processes still running | ✅ Visible as `active` in Deployment view |
| `db.demo.docs.countDocuments()` from mongos | ✅ Returns 50000 (all data reachable) |
| `sh.status()` from mongos | ✅ Still lists `poShard_2` with its chunks |
| Pre-exit snapshots auto-enqueued | ✅ Fresh snapshot taken on poShardClust within ~2 min of restoration-mode exit |

### Bottom line

**Without OM Backup Phase 1, Step 5's appdb rollback would cause
Step 4's migrated chunks to become unreachable through the mongos**,
because the agent would stop poShard_2's mongods on its next poll.

**With OM Backup Phase 1, the same Step 5 triggers regression
detection within seconds**, the agent's cached config is merged back,
poShard_2 stays managed, and the customer never notices that the
appdb was rolled back.

---

## Appendix A — Verification queries

### Identify the current appdb config version

```bash
mongosh "mongodb://127.0.0.1:27018/automationcore?directConnection=true" --quiet --eval '
db["config.automation"].findOne(
  {groupId: ObjectId("<GROUP_ID>")},
  {version:1, "cluster.processes.name":1}
)'
```

### Check restoration mode state on a group

```bash
mongosh "mongodb://127.0.0.1:27018/mmsdbconfig?directConnection=true" --quiet --eval '
db["config.customers"].findOne(
  {_id: ObjectId("<GROUP_ID>")},
  {n:1, restorationMode:1, restorationModeMetadata:1}
)'
```

### Confirm chunks actually exist on `poShard_2`

```js
// From the customer mongos
db.getSiblingDB("config").chunks.aggregate([
  {$match: {ns: "demo.docs"}},
  {$group: {_id: "$shard", count: {$sum: 1}}}
]);
```

### List all snapshots taken after restoration-mode exit

```bash
mongosh "mongodb://127.0.0.1:27018/backupjobs?directConnection=true" --quiet --eval '
db.snapshots.find(
  {groupId: ObjectId("<GROUP_ID>"), startTime: {$gte: new Date("<RESTORATION_EXIT_TIMESTAMP>")}},
  {_id:1, rsId:1, startTime:1, completed:1}
).sort({startTime:-1}).toArray()'
```

## Appendix B — Expected log signals on Primary OM

Tail the OM log during Step 6:

```bash
tail -f /tmp/primary-om.log | grep --line-buffered -E \
  "ReconciliationOrchestrator|ReconciliationConfigSvc|RestorationModeSvc|GroupDao.tryClearRestorationMode|AgentJobSvc.*CONFIG_UPLOAD"
```

Successful run looks like (timestamps + threading omitted):

```
ReconciliationOrchestrator     Collected metadata from 1/1 agents for group <GROUP_ID>
ReconciliationOrchestrator     Selected canonical config: host=<HOST>, version=<N+k>
AgentJobSvc                    Created AgentJob CONFIG_UPLOAD
ReconciliationOrchestrator     Submitted CONFIG_UPLOAD job to host <HOST>
... (waiting for agent to upload)
ReconciliationOrchestrator     Received <BYTES> bytes of config data from host
ReconciliationConfigSvc        Adapting unwrapped agent format
ReconciliationConfigSvc        Merging uploaded config (version N+k, M processes) into published config (version N)
ReconciliationConfigSvc        Bumped config version N+1 → N+k to prevent re-trigger
ReconciliationConfigSvc        Persisted reconciled config, new version: N+k
GroupDao.tryClearRestorationMode    Restoration mode cleared for group
RestorationModeSvc             Enqueuing pre-exit on-demand snapshots
RestorationModeSvc             Enqueued pre-exit snapshot for replica set <RS>
RestorationModeSvc             Enqueued pre-exit snapshot for cluster <CLUSTER_ID>
RestorationModeSvc             Exited restoration mode for group
ReconciliationTriggerSvc       Reconciliation succeeded for group
```

The whole chain typically completes in **20–40 seconds** from the moment
the agent's next poll hits OM with the cached `cv=`.

## Appendix C — Test record

_Captured during 2026-05-31 demonstration run on local PoC (Meta OM + Primary OM + 1-replica-set + 1-sharded-cluster topology with backing DBs in Docker)._

### Common setup (executed once, before either test)

| Field | Value |
|---|---|
| Date of run | 2026-05-31 |
| Project name | OM Backup |
| Group ID | `69ef3ca159819e73bb7f8552` |
| `T_baseline` (appdb snapshot before poShard_2 added) | **15:03 UTC** |
| `T_post_shard` (appdb snapshot AFTER poShard_2 + data migration; recovery point) | **15:30 UTC** |
| Sharded collection seeded | `demo.demo_docs` (hashed shard key on `sk`) |
| Docs inserted | **50,000** (~10 MB total, 200 bytes each) |
| poShard_2 ports | 27067 (primary), 27068 (secondary) — 2-member RS |
| Default chunk size adjusted | 128MB → **1 MB** (to encourage auto-rebalance without manual moveChunk) |
| Pre-rollback config version | **114** (was 113 before adding poShard_2) |
| Pre-rollback chunk distribution | `poShard_2: 3 chunks`, `poShard_1: 1 chunk`, `config: 1 chunk` (5 total) |
| Pre-rollback docs physically on poShard_2 (direct query to mongod) | **11,955** (≈ 24% of total) |
| Pre-rollback `countDocuments()` via mongos | 50,000 (all chunks reachable) |
| Migration evidence in `config.changelog` | `poShard_1 → poShard_2` at 15:25:57 UTC, `config → poShard_2` at 15:25:58 UTC (auto-balancer, not manual moveChunk) |

### Test 1 — Data Loss (restorationMode = DISABLED)

| Field | Value |
|---|---|
| Primary OM JVM flag | `-Dmms.featureFlag.automation.restorationMode=disabled` |
| Restoration-mode flag at start (verified) | `restorationMode: false` on customer doc |
| poShard_2 mongods at start | Both alive (PIDs 30440 on :27067, 30441 on :27068), serving 11,955 docs directly |
| Time appdb restore submitted (Meta OM) | _TBD_ |
| Time appdb restore completed | _TBD_ |
| Time agent next poll after rollback | _TBD_ |
| Time poShard_2 mongods stopped by agent | _TBD_ |
| `countDocuments()` via mongos AFTER agent reacts | _TBD_ — **expected: error or partial count < 50,000** |
| `mongosh mongodb://localhost:27067` direct connect AFTER | _TBD_ — **expected: connection refused** |
| poShard_2 in OM UI Deployment view AFTER | _TBD_ — **expected: missing / processes removed** |
| OM log entries (no `ReconciliationOrchestrator`, no `RestorationModeSvc`) | _TBD_ — confirms no safety net engaged |
| Outcome | _TBD_ |

### Test 2 — Data Retention (restorationMode = ENABLED)

| Field | Value |
|---|---|
| Primary OM JVM flag | `-Dmms.featureFlag.automation.restorationMode=enabled` |
| Recovery point used to restore env between tests | `T_post_shard` (15:30 UTC) |
| Restoration-mode flag at start (verified) | `restorationMode: false` (cleared) |
| Time appdb restore submitted (Meta OM) | _TBD_ |
| Time appdb restore completed | _TBD_ |
| Time restoration-mode banner appeared on Primary OM UI | _TBD_ |
| OM log: full reconciliation chain (paste) | _TBD_ |
| Time restoration-mode banner cleared | _TBD_ |
| Pre-exit snapshots enqueued (poRepSet + poShardClust) | _TBD_ |
| Post-recovery config version | _TBD_ — expected ≥ 114 (preserved from agent's cache) |
| Post-recovery chunk distribution | _TBD_ — expected: 3 chunks still on poShard_2 |
| Post-recovery `countDocuments()` via mongos | _TBD_ — **expected: 50,000 (no loss)** |
| Outcome | _TBD_ |


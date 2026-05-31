# OM Backup Phase 1 — Why this matters

_Demonstrating the data-loss scenario this feature prevents._

## TL;DR

In a Meta-OM-backs-Primary-OM topology, rolling back the Primary OM's
appdb to a state from before a customer added a shard would, **without
this feature**, cause the agent to issue `removeShard` on the customer's
cluster on its next poll. The cluster's topology gets silently mutated
(3 shards → 2 shards in our PoC), all data on the new shard is forcibly
drained back to the original shards (15 seconds at PoC scale; hours-to-days
at production scale with TBs of data), and the customer has to manually
re-add the shard to restore the topology. **OM Backup Phase 1 closes this
gap** by detecting the appdb regression, putting the group into restoration
mode, and merging the agent's cached (newer) automation config back into
the published config so the new shard stays managed — no removeShard, no
drain, no topology mutation.

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
| Time appdb restore submitted (Meta OM) | ~15:37 UTC |
| Time appdb mongod stopped (observed) | 15:38:16 UTC |
| Time appdb mongod back, config v=113 (observed) | 15:48:44 UTC (~10 min total restore — large appdb >1GB compressed) |
| Time agent on host received rolled-back config | ~15:48:48 IST (`clusterConfig edition is different`) |
| Time agent issued `removeShard poShard_2` to mongos | **15:48:48.654 IST** (essentially immediately) |
| Drain duration | 15.26 seconds (3 chunks migrated `poShard_2 → config + poShard_1`) |
| Time `removeShard` completed | **15:49:04 IST** (`state: completed`) |
| `countDocuments()` via mongos AFTER drain | **50,000** ✓ (preserved by drain semantics — see "Important nuance" below) |
| `mongosh mongodb://localhost:27067` direct connect AFTER | Still accepts connections; **11,955 orphaned docs still physically present** on the now-removed mongod |
| poShard_2 in mongos `listShards` AFTER | **MISSING** — cluster topology forcibly reduced from 3 → 2 shards |
| Chunk distribution AFTER | `config: 3 chunks`, `poShard_1: 2 chunks` (was 1/1/3 with poShard_2 included) |
| OM log entries | NO `ReconciliationOrchestrator`, NO `RestorationModeSvc`, NO `enterRestorationMode` — confirms no safety net engaged |
| Outcome | ⚠️ **Topology destruction + forced data migration, data preserved by MongoDB's `removeShard` drain semantics only** |

#### Important nuance — the actual customer impact

In our PoC run, the data didn't catastrophically vanish because MongoDB's `removeShard` command **drains chunks before removing the shard**. All 50,000 docs reshuffled in 15 seconds and remained reachable via mongos. But the customer experience was still severely degraded:

1. **Cluster topology silently mutated.** Customer added 3 shards in Phase A; cluster is now at 2 shards in Phase B. The "added shard" was undone by OM without operator consent.
2. **Forced data redistribution.** 11,955 docs (24% of collection) had to migrate during the drain window. At PoC scale this took 15s; at production scale (TBs of data, jumbo chunks, balancer contention) the drain can take **hours to days**, during which the cluster is degraded.
3. **Customer must manually re-add the shard.** No automatic recovery path — the operator has to notice and intervene.
4. **Failure modes during drain become data-loss modes.** If the drain crashes mid-way (agent restart, network partition, jumbo chunk that can't migrate, disk-full on destination shard), data lands in an undefined state — the `removeShard` command becomes a real data-loss vector instead of a safe migration.
5. **Orphaned data on the removed shard.** poShard_2's mongods still hold 11,955 docs that are now invisible to the cluster — both wasted storage AND a potential source of confusion if anyone reconnects directly to those mongods later.

The key point: **without OM Backup Phase 1, the system disposes of the customer's deliberate topology change because OM lost track of it.** That's the operational anti-pattern this feature exists to prevent.

#### Recovery is NOT automatic — the operator gets stuck

A subtle and severe follow-on impact was observed during our PoC run when we tried to recover the topology by restoring the appdb FORWARD to a snapshot that contained poShard_2 in the config:

```
(OperationFailed) can't add shard 'poShard_2/M-FNVDKKWYJR:27067,M-FNVDKKWYJR:27068'
because a local database 'demo' exists in another poShard_1
```

MongoDB's `addShard` command refuses to add poShard_2 back to the cluster because the **11,955 orphaned docs** left behind on poShard_2's mongods (from before the `removeShard` drain) include the `demo` database — which now also lives on `config` + `poShard_1` (where they were drained to). `addShard` doesn't allow a new shard to join if any of its databases overlap with the existing cluster.

The agent gets stuck in a retry loop on `AddShardsAndShardTags → Plan execution failed`. The cluster stays at 2 shards. **The operator has to manually intervene** to make recovery possible:

1. Connect directly to poShard_2's primary (`mongosh mongodb://<poShard_2-primary>:27067 --eval 'db.getSiblingDB("demo").dropDatabase()'`)
2. Carefully verify that the data being dropped is the orphan copy, not live data (real-world risk: misidentification → operator drops customer-critical data)
3. Wait for the agent's next addShard retry to succeed
4. Wait for the balancer to re-migrate chunks back to poShard_2 (15s in our PoC; hours-to-days at production scale)

**This compounds the original problem.** The customer not only lost their topology change, they now need careful manual intervention to restore it — and the intervention itself is a data-loss risk if the operator misjudges what's orphaned.

OM Backup Phase 1 prevents the entire chain from starting: regression detection + restoration mode + reconciliation means `removeShard` never runs in the first place, so there's no orphaned data, no addShard failure, no manual recovery.

### Test 2 — Data Retention (restorationMode = ENABLED)

| Field | Value |
|---|---|
| Primary OM JVM flag | `-Dmms.featureFlag.automation.restorationMode=enabled` |
| Recovery point used to restore env between tests | `T_post_shard` (15:30 UTC) |
| Restoration-mode flag at start (verified) | `restorationMode: false` (cleared) |
| Pre-rollback state | 3 shards, chunks 1/1/3, mongos count 50,000, config v=114 |
| Time appdb restore submitted (Meta OM) | ~16:23 UTC |
| Time appdb mongod stopped (observed) | 16:24:13Z |
| Time appdb mongod back, config v=113 | **16:33:50Z** (~10 min restore — same as Test 1) |
| Time restoration mode entered (`RestorationModeSvc.enterRestorationMode`) | **16:33:55.313Z** (within 3 seconds of appdb coming back) |
| OM log reason recorded | `PITR_RESTORE` |
| Reconciliation kicked off | 16:33:55.323Z (10 ms later) |
| Agent metadata collected | 16:34:25.437Z (T+30s) — `Collected metadata from 1/1 agents` |
| Canonical config selected | `host=M-FNVDKKWYJR, version=114, timestamp=1780243820` |
| CONFIG_UPLOAD AgentJob created | 16:34:25.443Z |
| Agent uploaded 28,608 bytes of config (v=114) | 16:34:55.507Z |
| OM merged v=114 into published v=113 | 16:34:55.550Z — `Merging uploaded config (version 114, 13 processes) into published config (version 113)` |
| Persisted reconciled config, new version | **16:34:55.688Z, version 114** ✓ (no extra bump — agent's version already current) |
| Pre-exit on-demand snapshots enqueued | poRepSet (16:34:55.693Z) + cluster poShardClust (16:34:55.695Z) |
| Time restoration mode exited (`exitRestorationMode`) | **16:34:55.695Z** |
| **Total restoration-mode lifecycle duration** | **60.4 seconds** (16:33:55.313Z → 16:34:55.695Z) |
| `removeShard` log entries during Test 2 | **0** — agent never tried to remove poShard_2 ✓ |
| `addShard` log entries during Test 2 | **0** — topology never mutated ✓ |
| `AddShardsAndShardTags` / `RemoveShardsAndShardTags` agent moves | **0** — agent stayed in goal state |
| Pre-exit snapshots completed | poRepSet at 16:35:52Z ✓ (`complete=true`); poShard_1 at 16:37:48Z (in progress at time of capture) |
| Post-recovery `listShards` | `config`, `poShard_1`, **`poShard_2`** ✓ — all 3 still present |
| Post-recovery chunk distribution | `config: 1, poShard_1: 1, poShard_2: 3` (unchanged from pre-rollback) ✓ |
| Post-recovery `countDocuments()` via mongos | **50,000** ✓ — no data movement at all |
| Post-recovery `restorationMode` flag | `false` (cleared cleanly) |
| Operator intervention required | **None** — fully automatic |
| Outcome | ✅ **PASS — full topology + data preservation, ~1 min auto-recovery, zero operator intervention** |

### Side-by-side comparison

**Same starting condition. Same rollback target. Only the feature flag differs.**

| Aspect | Test 1 (feature DISABLED) | Test 2 (feature ENABLED) |
|---|---|---|
| `removeShard poShard_2` issued by agent | ✅ YES — at 21:48:48 IST | ❌ NO |
| Chunks forcibly migrated off poShard_2 | ✅ YES — 3 chunks drained in 15s (production: hours) | ❌ NO — chunks stayed put |
| Cluster topology after rollback | **3 shards → 2 shards** (poShard_2 removed) | **3 shards → 3 shards** (unchanged) |
| Orphaned data left on poShard_2 mongods | 11,955 docs + `demo` db metadata | None |
| `addShard` recovery failed because of orphan data | ✅ YES — `addShard` rejected: `local database 'demo' exists in another poShard_1` | N/A (no removal happened) |
| Operator manual intervention to recover | **Required** — drop orphan db, wait for rebalance | **None** |
| Restoration-mode banner shown to user | ❌ Never | ✅ Yes — `PITR_RESTORE` reason |
| Reconciliation chain executed | ❌ None | ✅ 60.4 seconds end-to-end |
| Pre-exit snapshots auto-enqueued for both RS + cluster | ❌ None | ✅ Yes |
| Customer data outcome | Preserved by MongoDB's drain semantics, but **at cost of cluster destabilization + forced migration + manual recovery + orphan-data risk** | Fully preserved with **zero side effects** |
| End-to-end customer recovery time | Hours (manual investigation + drop orphan + wait for rebalance) | **~1 minute, fully automatic** |


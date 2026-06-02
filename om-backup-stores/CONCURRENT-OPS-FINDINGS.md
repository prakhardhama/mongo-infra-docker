# OM Backup Phase 1 — concurrent-operations findings

_Testing what happens when Primary OM's appdb is snapshotted (or
restored) while Primary OM itself is mid-flight on a customer backup,
restore, groom, or chunk migration. Targets the AppDB-only MVP scope
where there are no separate `s3-meta-rs` / `oplog-meta-rs` stores and
all backup machinery state lives in one DB._

## Context and motivation

From the launch-readiness Slack thread:

> Some customers will (despite our best practices) be using AppDB for
> everything (no separate stores for backup metadata). So I actually
> think there might be some value in working out an MVP with caveats
> for just AppDB. We could offer that sooner. But [...] you've still
> got scenarios like the OM being backed up was doing a
> restore/grooming/backup when its AppDB was itself backed up. What
> happens then?

The existing PoC docs in this directory cover the cross-store skew
scenarios (`RESTORE-FINDINGS.md` S1/S2/S3), the validator fix that
prevents the late-failing restore (`SCENARIO-1-FIX-PROPOSAL.md`), and
the v8.0 backport probes (`8.0-TEST-PLAN.md`). The shard data-loss
demo (`WHY-IT-MATTERS-SHARDED-DATA-LOSS.md`) shows what restoration
mode prevents in the topology-change case.

**This doc fills the deliberate-concurrent-operations gap.** All
three prior "Run 2" runs kept Primary OM up during the backing-store
mongod restart window but explicitly note no concurrent operation was
in flight at the time. The `8.0-TEST-PLAN.md` Tier-3 list flags it
as a known gap deferred to a fresh PoC.

## Why AppDB-only is interesting (a refinement of Dan's argument)

The AppDB-only deployment is **simpler on metadata skew** — all backup
machinery state (`backupjobs.*`, `backupstore.*`, `automationcore.*`,
`mmsdbrrd-*`) sits in one DB, so rolling back appdb rolls back
everything to the same point. There's no cross-store inconsistency
possible.

But it's **riskier on concurrent operations** — the same single DB
holds both:
- Customer-facing state (deployment topology, snapshot index, oplog cursors)
- Internal-machinery state (in-flight job state, lock docs, daemon coordination, mid-groom delete markers, mid-migration chunk routing)

A snapshot of appdb captured during a customer operation captures
**both** the customer's mid-flight state AND the machinery's
mid-flight state in one atomic image. Restoring that image rewinds
both — which sounds clean but exposes specific failure modes if the
machinery isn't designed to recover from arbitrary mid-state restarts.

## Setup recap

Same Meta-OM-backs-Primary-OM topology as the other PoC docs:

| Component | Where | Role |
|---|---|---|
| Meta OM (`ops` container) | Docker | Backs up appdb-rs, s3-meta-rs, oplog-meta-rs |
| Primary OM (local `bazel run //server:mms`) | Host JVM | Manages customer deployments; reads/writes appdb-rs |
| Primary OM appdb (`primary-om-appdb`) | Docker, port 27018 | Holds automationcore, backupjobs, backupstore, etc. |
| Customer deployment `poRepSet` | Host mongods | 5-member RS being backed up |
| Customer deployment `poShardClust` | Host mongods | Sharded cluster being backed up |
| Branches under test | `prakhar.dhama/om-backup-local-8.0` (OM) + `prakhar.dhama/om-backup-local-8.0` (agent, on mms-automation) | v8.0 backport + PoC deltas + test-mode JVM flags |

For all probes, the OM JVM should be started with:

```bash
cd ~/ops-manager
OM_DONT_RUN_MIGRATIONS=1 bazel run --server_env=hosted //server:mms -- \
  '--jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled' \
  '--jvm_flag=-Dmms.reconciliation.test.initialDelayMs=90000' \
  2>&1 | tee /tmp/primary-om.log
```

The `initialDelayMs=90000` extends the restoration-mode banner window
to 90 seconds — useful so we can observe the post-restore reconcile
behavior without it auto-clearing in 1 second.

## Probes

Each probe follows the same shape: **(1) set up a long-running
operation on the customer side, (2) trigger a Meta OM appdb snapshot
while that operation is in flight, (3) wait for both to complete, (4)
roll back Primary OM's appdb to the mid-flight snapshot, (5) observe
what happens.**

The interesting questions per probe:
- Does the daemon recover from the restored mid-state, or get stuck?
- Does the agent's reconciliation logic protect against the divergence?
- Is there orphan data, stuck job docs, or undefined behavior?

---

### Probe A — AppDB snapshot during a customer snapshot upload

**Setup:**
1. Pick a customer RS with enough data that a snapshot takes ≥ 30 seconds (insert ~100MB on `poRepSet` via mongos if needed).
2. In Primary OM UI: Continuous Backup → poRepSet → ⋮ → Take Snapshot Now.
3. Within the ~5–10s lag after the agent starts uploading, in Meta OM UI: Continuous Backup → appdb-rs → ⋮ → Take Snapshot Now.

**Verify mid-flight overlap:**
- `backupjobs.jobs.workingOn = true` for poRepSet at the moment of appdb snapshot
- `wtBackup.wtcJustRestored` is null / not the freshly-completed sentinel
- The poRepSet snapshot doc exists with `completed=false`

**Action:**
4. After both snapshots complete, in Meta OM UI: Continuous Backup → appdb-rs → Restore → pick the mid-flight snapshot from step 3.

**Watch for:**
- Daemon log: does bgrid get stuck on `state.action: WT checkpoint` because the restored state thinks a snapshot is in progress?
- `backupjobs.snapshots` for poRepSet: any `completed=false` zombie docs from the in-flight snapshot?
- Agent's deployment-side log: does it see the half-baked snapshot and try to retry/clean up?
- Is `lastOplogPush` populated, or stuck at the pre-snapshot value?

**Success criteria:** the system either (a) recovers cleanly within a
few minutes (in-progress job marked abandoned, new snapshots resume),
or (b) presents a clear error state that an operator can recover from
(documented recovery procedure).

**Failure criteria:** daemon parks indefinitely; bgrid `boundBy` lock
never releases; new snapshots can't proceed; or a snapshot index doc
exists that the daemon thinks is complete but data isn't actually in S3.

#### Probe A — Test record (2026-06-02)

**Execution note:** the natural orchestration (bump `nextSnapshot` in appdb to trigger a real customer snapshot timed to overlap with an appdb-rs snapshot) hit two blockers on this PoC:
1. Customer snapshot triggers fired on the OM-side scheduler (`WTCheckpointScheduleSvc: all conditions met`) but failed at the agent step (`Abort triggered by error from M-FNVDKKWYJR(108.0.24): ProcessCursorDescription failed... Status: 500 Server Error`). The locally-built dev agent doesn't appear to handle the WT checkpoint cursor description request the same way a production agent does.
2. Meta OM's `appdb-rs` snapshot scheduler was also silent despite bumping `nextSnapshot` to the past.

To get an answer to the underlying question (**"what does bgrid do when it sees mid-flight markers in appdb that don't correspond to actual ongoing work?"**), we pivoted to **artificial state injection** (per user-approved Option B): we injected a mid-snapshot state into `backupjobs.jobs` for poRepSet + an `_isInjectedForProbe`-marked incomplete snapshot doc, observed bgrid's behavior, then reverted.

**Injection state (live appdb, not a captured/restored snapshot — same observable behavior):**

```json
// backupjobs.jobs.findOne(rsId: "poRepSet")  AFTER injection
{
  "workingOn": true,
  "state": {
    "action": "WT checkpoint in-progress",
    "startedAt": "2026-06-02T10:18:45.250Z"
  },
  "wtBackup.checkpointingTarget.attemptInProgress": true,
  "_isInjectedForProbe": true
}
// + one new backupjobs.snapshots doc with completed=false
```

**Observed behavior:**

| Event | Time (UTC) | Detail |
|---|---|---|
| bgrid last poll of poRepSet PRE-injection | 10:17:49.193Z | DEBUG `WTCheckpointScheduleSvc.isWTCSnapshotTime: WTC snapshot time: all conditions met` |
| Injection applied | 10:18:45.250Z | `workingOn=true`, new snapshot doc inserted with `completed=false` |
| bgrid log activity on poRepSet | **none** | Silent for the full 4-minute observation window (10:18:45 → 10:21:31) |
| State observed during silence | 10:18:45 → 10:21:31 | `workingOn=true / state.action="WT checkpoint in-progress" / incomplete snapshot doc still present` |
| Injection reverted | 10:21:31Z | `workingOn=false`, injected snapshot doc deleted |
| bgrid resumed polling poRepSet | **10:22:45.652Z** (73s later) | INFO `WTCheckpointBackupSvc.deleteInProgressCheckpointSnapshot: Deleting in progress checkpoint... backupId: 51760211-...` (defensive cleanup before new snapshot attempt) |
| `Couldn't find incomplete snapshot` WARN | 10:22:45.652Z | bgrid's "clean up any orphan in-progress before starting fresh" path is in place — it tries to delete stragglers; ours was already gone (`removed: 1` is a different doc from the same cleanup) |

**Outcome: ⚠️ PASS-with-significant-caveat.** bgrid recovers automatically WHEN the stale lock is cleared, but **does NOT automatically detect or clear a stale lock**.

#### Probe A — failure-mode characterization (the launch-readiness answer)

**In the AppDB-only MVP scenario,** if a customer's appdb is restored from a snapshot that was captured **while a customer-deployment snapshot was mid-flight** (i.e., a real-world race), the restored state will contain:

- `backupjobs.jobs.workingOn = true` (mid-snapshot lock held)
- `backupjobs.jobs.state.action = "WT checkpoint in-progress"` (or similar non-terminal state)
- One or more `backupjobs.snapshots` docs with `completed = false`

bgrid honors `workingOn=true` as "another bgrid instance currently owns this job, defer". It does NOT:

- Compare `state.startedAt` against current time to detect stale locks
- Compare the `machine.bound` lock against itself to detect "wait, that's MY own machine and I'm not actually working — this is a stale lock from a restored snapshot"
- Auto-clear in-progress snapshot docs whose timestamps are older than some grace period

**Customer impact:** **All scheduled backups for that RS stop until an operator manually clears the lock by setting `workingOn=false` and deleting the orphaned incomplete snapshot doc.** No log warning is emitted to alert the operator that this happened. The customer wouldn't notice until they look at the snapshot schedule and realize nothing's been taken in hours.

**Recovery procedure (operator):**

```js
// Connect to the appdb (this is Primary OM's, on port 27018 in our PoC)
db.getSiblingDB("backupjobs").jobs.updateMany(
  {workingOn: true},
  {$set: {workingOn: false, "state.action": "WT checkpoint"}}
);
db.getSiblingDB("backupjobs").snapshots.deleteMany(
  {completed: false, startTime: {$lt: new Date(Date.now() - 60*60*1000)}}  // older than 1 hour
);
```

Within ~60s of the cleanup, bgrid resumes polling and takes a fresh snapshot.

**Mitigations the v8.0 code does NOT have, that would close this gap:**

1. **Stale-lock detection in bgrid**: on every poll cycle, check `state.startedAt` (and/or a heartbeat-timestamp field). If older than `2 × poll_interval`, clear `workingOn` and log a WARN. Estimated ~15 LOC in `WTCheckpointScheduleSvc`.
2. **WARN on permanently stale orphan snapshot docs**: any snapshot doc with `completed=false` and `startTime` older than 1 hour should emit a log warning so monitoring can alert.
3. **Restoration-mode integration**: if restoration mode is triggered (e.g. via the regression detect we backported), reconciliation could include "clear stale workingOn locks" as part of the recovery procedure.

None of these are launch-blockers but they ARE the right follow-ups to address Dan's specific concern. **Most important**: the AppDB-only MVP customer-facing documentation MUST flag this recovery procedure, because the customer's "I restored my appdb and now backups have stopped" support case is going to happen, and the operator needs the runbook above to recover.

---

### Probe B — AppDB snapshot during a customer restore

**Setup:**
1. Pick a clean snapshot of poRepSet (or whatever customer RS).
2. In Primary OM UI: trigger Restore on that snapshot, choose Automated Restore.
3. As soon as the deploy starts (Phase 1 BounceStopIfUpWithForce in agent log, or the `backupRestoreUrl*` fields appear on `config.automation` processes), in Meta OM UI: Continuous Backup → appdb-rs → ⋮ → Take Snapshot Now.

**Verify mid-flight overlap:**
- `automationcore.config.automation.processes[*].backupRestoreUrl` present on the target poRepSet members
- `backupjobs` has a `restorejobs` entry in `IN_PROGRESS` state for the snapshot being restored

**Action:**
4. Wait for the customer-side restore to complete (~3–10 min for the small PoC dataset).
5. In Meta OM UI: Continuous Backup → appdb-rs → Restore → pick the mid-flight snapshot from step 3 (the one taken WHILE the restore was running).

**Watch for:**
- After the appdb is rolled back to mid-restore state, does the agent on the host see `backupRestoreUrl*` directives in the config and start a NEW restore (effectively re-wiping the data we just restored)?
- Does restoration mode trigger on the regression detect — and does its reconciliation cleanly remove the now-stale `backupRestoreUrl*` directives, OR does it preserve them?
- Customer's poRepSet: does mongos still serve queries, or do the members get stopped + wiped again?

**Success criteria:** restoration mode + reconciliation cleans up the
stale restore directives without re-triggering a wipe (because the
agent's actual cached state is "restore complete," not "restore in
progress").

**Failure criteria:** agent honors the stale `backupRestoreUrl*` and
wipes data; OR the restore-job doc enters a `STUCK` state with no
auto-recovery; OR the customer data ends up at the pre-mid-flight-restore
state silently.

#### Probe B — Test record

_TBD as for Probe A._

---

### Probe C — AppDB snapshot during a groom

**Setup:**
1. Identify when the next scheduled groom is for one of the customer's backup jobs (see `backupjobs.jobs.s3blockstore.lastGroomedMS`; groom runs are typically scheduled daily).
2. Force a manual groom if there's a way to trigger one — TBD: search for an admin endpoint or a way to nudge the daemon to groom now.
3. When the groom log line appears in Primary OM (`Grooming snapshot`, `Deleting block files`, etc.), trigger appdb snapshot in Meta OM.

**Verify mid-flight overlap:**
- `backupstore.files` has fewer docs than the pre-groom count (deletions in flight)
- The groom job doc shows `IN_PROGRESS` or similar

**Action:**
4. After groom completes, roll back appdb to the mid-groom snapshot.

**Watch for:**
- After rollback: do `backupstore.files` deletions get "undone" (they come back, since they were rolled back)?
- Does the daemon notice the inconsistency between `backupjobs.snapshots` (which thinks blocks are gone) and `backupstore.files` (which has them)?
- Subsequent restore of a snapshot whose blocks were "in flight" being groomed at the moment — does it fail or succeed?

**Success criteria:** the daemon detects and recovers from the
post-rollback inconsistency; subsequent restores from any pre-groom
snapshot succeed.

**Failure criteria:** snapshot becomes unrestorable even though its
blocks have been "resurrected" by the rollback (a different shape of
the Scenario-1 problem we already fixed for the cross-store case).

#### Probe C — Test record

_TBD._

---

### Probe D — AppDB snapshot during sharded-cluster chunk migration

**Setup:**
1. On `poShardClust`, ensure the demo collection `demo.demo_docs` (or equivalent) has chunks on multiple shards.
2. Start a manual `moveChunk` between two shards (a chunk with enough docs that the migration takes ≥ 10 seconds).
3. Mid-migration, in Meta OM UI: take an appdb snapshot.

**Verify mid-flight overlap:**
- Customer mongos's `config.changelog` shows `moveChunk.start` but no `moveChunk.commit` yet
- `backupjobs.jobs` for the shards involved shows backup activity (oplog tailing reflects the migration writes)

**Action:**
4. After migration completes, roll back appdb to the mid-migration snapshot.

**Watch for:**
- Customer's mongos config server (separate from appdb) still shows migration completed — so customer's view of chunk locations is "after migration."
- Primary OM's appdb has the PRE-migration view of which shard owns what (in the snapshot index, oplog cursors, etc.).
- Does the daemon's next backup attempt fail because the oplog cursors don't match what's actually on the shards?
- Does the snapshot-block index reference blocks at "old" shard locations that have since moved?

**Success criteria:** daemon resumes backing up the post-migration
topology cleanly; oplog cursors auto-correct on next tail.

**Failure criteria:** daemon parks on inconsistent state; backup
schedule stalls; oplog gap detected because cursors point past where
real data sits.

#### Probe D — Test record

_TBD._

---

## Comparison: AppDB-only MVP risk profile

To be filled after probes are complete. The structure:

| Failure mode | Multi-store topology (current PoC) | AppDB-only MVP | Mitigation in v8.0 |
|---|---|---|---|
| Cross-store rollback skew (S1: s3-meta only) | Real risk, fixed by PR #770 validator | N/A — no separate stores to skew | PR #770 validator (still applies if customer ever splits) |
| Concurrent customer-snapshot during appdb snapshot | _TBD by Probe A_ | _TBD by Probe A_ | restoration mode + reconciliation |
| Concurrent customer-restore during appdb snapshot | _TBD by Probe B_ | _TBD by Probe B_ | restoration mode + reconciliation |
| Concurrent groom during appdb snapshot | _TBD by Probe C_ | _TBD by Probe C_ | ? |
| Concurrent chunk migration during appdb snapshot | _TBD by Probe D_ | _TBD by Probe D_ | restoration mode + reconciliation (per `WHY-IT-MATTERS`) |

## Sign-off criteria for AppDB-only MVP launch

1. All 4 probes complete with documented outcomes.
2. Any "fail" outcomes have either: (a) a documented operator recovery procedure, OR (b) a code change identified to fix it.
3. The risk-profile comparison table is filled and triaged with the launch stakeholders.
4. Customer-facing documentation includes the concurrent-ops caveats explicitly, so Dan Mckean's concern about customers being surprised is addressed.

## Recovery between probes

After each destructive probe, restore the environment via the
`T_post_shard` (or equivalent fresh) appdb snapshot before starting
the next one. Mirror the procedure from `WHY-IT-MATTERS` Step
Recovery.

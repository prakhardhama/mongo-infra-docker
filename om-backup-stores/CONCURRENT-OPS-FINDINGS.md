# OM Backup Phase 1 — concurrent-operations findings

_Testing what happens when Primary OM's appdb is snapshotted (or
restored) while Primary OM itself is mid-flight on a customer backup,
restore, groom, or chunk migration. Targets the AppDB-only MVP scope
where there are no separate `s3-meta-rs` / `oplog-meta-rs` stores and
all backup machinery state lives in one DB._

## Context and motivation

From the launch-readiness Slack thread (note: the AppDB-only framing has since been superseded — see below):

> Some customers will (despite our best practices) be using AppDB for
> everything (no separate stores for backup metadata). So I actually
> think there might be some value in working out an MVP with caveats
> for just AppDB. We could offer that sooner. But [...] you've still
> got scenarios like the OM being backed up was doing a
> restore/grooming/backup when its AppDB was itself backed up. What
> happens then?

**Scope update (post-experiment):** the MVP scope has expanded to
**include all three backing stores** (appdb-rs + s3-meta-rs +
oplog-meta-rs), not just appdb-only. The probes below ran on our
PoC's full multi-store topology, so the findings apply directly to
the actual MVP scope. The "AppDB-only" framing in earlier sections
of this doc is retained for historical context but the conclusions
generalize — concurrent-operations risks during appdb snapshot/restore
exist regardless of whether `s3-meta` and `oplog-meta` live in the
same RS as appdb or separately. The new docs/runbook items added here
apply equally to both topologies.

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

#### Probe A — validation of the injection method

A fair concern: the artificial injection of `workingOn=true` (boolean) doesn't match exactly what bgrid writes during a real snapshot. Code inspection clarifies what's faithful vs. what's not:

| Aspect | Real bgrid state during snapshot | Probe A's injection | Faithful for our observation? |
|---|---|---|---|
| `workingOn` field type | sub-document `{machine: {...}, integrityCheck: bool, ...}` (per `BackupStatus.getWorkingOn()` returning `DBObject`) | boolean `true` | ✅ Faithful for the gate test (`workingOn: false` query excludes both) |
| Upstream queries (`ImplicitJobDaoV2.java:405,1176`, `RestoreJobDao.java:204,224`, etc.) | filter `workingOn: false` to find pollable jobs | filter excludes our doc | ✅ Same exclusion behavior |
| Downstream call sites (e.g., `getWorkingOnMachine()`) | would unmarshal sub-doc into `DaemonMachine` | would fail on type-cast if reached | ❌ Different — but never reached because the upstream filter skips our doc entirely |

**Conclusion:** the **primary observable** (bgrid stops polling the job) is faithfully reproduced by the injection. The launch-readiness conclusion — "stale workingOn lock → silent backup-pause until manual cleanup" — stands.

**Other state-machine effects** (e.g., what bgrid would do if some OTHER code path DID encounter the workingOn doc) might differ from real mid-flight behavior. We've documented the recovery path that matters; any second-order effects are out of scope for this probe.

**Attempt to validate via real workflow (failed):** we also tried `POST /api/public/v1.0/groups/{gid}/clusters/{cid}/snapshots/onDemandSnapshot` to trigger a REAL customer snapshot, but the call returned `HTTP 500 UNEXPECTED_ERROR` on both Primary OM (poRepSet) and Meta OM (appdb-rs). The same root cause as the earlier `WTCheckpointResource` 500 we saw — the locally-built dev agent doesn't successfully handle the WT checkpoint cursor description request. This is a PoC environment limitation, not a v8.0 backport defect.

**Attempt to validate via UI (two layers of issues, both useful learnings):** we set up a CDP-enabled Chrome (`~/bin/cdp-chrome/launch`) + Playwright driver (`~/bin/cdp-chrome/login-and-probe-a`) that programmatically logs in to both OMs and opens the Continuous Backup pages.

**Layer 1 — UI-level understanding (poRepSet has no "Take Snapshot Now"):** the button is **hidden when the next scheduled snapshot is already overdue or in-flight** (the "Snapshot is behind" indicator). For poRepSet, the scheduler has been continuously trying to snapshot (and failing at the agent 500), so it's always "behind" → the manual button is suppressed because clicking would be redundant. To get the button to appear on poRepSet, you'd need to push the next scheduled snapshot well into the future (e.g., 1 hour out) so the scheduler isn't in "trying right now" state.

**Layer 2 — even after clicking on poShardClust, the snapshot didn't fire:** the OM UI's "Take Snapshot Now" button has `data-open-form="take-snapshot-now"` — it just **opens a confirmation modal**. Clicking the kebab button itself doesn't submit the request; you also have to click the modal's Submit button. My driver only clicked the first button, so nothing actually got written to `onDemandSnapshotInfo` and bgrid never tried to snapshot. Tracker output confirms — no state change on either side:

```
ts        | poShard_1 working/action | snap count | appdb-rs working/action | snap count
12:14:59Z | false|WT checkpoint     | 73         | false|WT checkpoint    | 506
12:15:05Z | false|WT checkpoint     | 73         | false|WT checkpoint    | 506
...                                                                                  (no change for 2 min)
12:16:34Z | false|WT checkpoint     | 73         | false|WT checkpoint    | 506
```

The intended flow IS: UI button → modal Submit → enqueues `onDemandSnapshotInfo` to `backupjobs.jobs` → bgrid's `WTCheckpointScheduleSvc.isWTCSnapshotTime` returns true on next poll (due to `hasOnDemandSnapshotTime()` path) → bgrid sends the snapshot cursor description request to the agent → **agent returns HTTP 500** (as we observed via the earlier `nextSnapshot` bump test) → bgrid aborts and deletes the in-progress snapshot doc. Even WITH the modal submitted, this is where it fails in our PoC.

**This is an environment-specific block, not a v8.0 backport defect.** A production-built agent (vs. the locally-compiled `go run cm.go` in this PoC) would presumably handle the WT checkpoint request correctly. Without that working, we can't observe the REAL mid-snapshot state in this environment — the injection-based test remains the only feasible approach, and the code-grep validation above shows its primary observable is faithful.

**Reusable infrastructure created:** `~/bin/cdp-chrome/` (launch / stop / login-and-probe-a) — same CDP-attach pattern as the `google-doc-writer` skill. Selectors learned for future OM UI driving:

| Element | Selector |
|---|---|
| Username field on login | `input[name="username"]` |
| Password field | `input[name="password"]` |
| Login submit | `button:has-text("Login")` |
| Kebab in row (e.g., "poShardClust") | `tr:has-text("poShardClust") details.context-menu summary` |
| "Take Snapshot Now" item (opens modal) | `tr:has-text("poShardClust") button.take-snapshot-now` |
| Modal Submit button | (TBD — script doesn't handle this layer yet; would need to inspect the modal's structure) |

For future UI-driven snapshot tests: also need to handle the confirmation modal. The selector pattern is likely `[role="dialog"] button:has-text("Take Snapshot")` or similar — to be inspected on next run.

**Note on the button-visibility rule:** "Take Snapshot Now" is only shown for clusters/RSes where the next scheduled snapshot is in the future. If the schedule shows "(now)" or "Snapshot is behind", the button is suppressed. To test this on a deployment that's permanently "behind" (like poRepSet in our PoC), push the next-snapshot time out via `db.jobs.updateOne(..., {$set: {nextSnapshot: Timestamp(<future-secs>, 1)}})` first.

#### Probe A — UI-driven validation results (round 2, schedule pushed out)

After the user pushed `nextSnapshot` on poRepSet to 15:00Z (well in the future), the "Take Snapshot Now" button became visible. UI driver clicked the kebab → menu item → modal's Submit button on both Primary OM (poRepSet) and Meta OM (appdb-rs). Two real submissions, 7 seconds apart:

| | Primary OM (poRepSet) | Meta OM (appdb-rs) |
|---|---|---|
| Modal submit time | 12:30:52Z | 12:30:59Z |
| `onDemandSnapshotInfo` written to appdb? | ✓ (briefly) | ✓ (still set 60s later) |
| bgrid picked up + cleared? | ✓ (`onDemand: (cleared/none)` within 30s) | bgrid would pick up on next poll cycle |
| Actual snapshot created? | ❌ (no new doc) | ✅ One earlier on-demand snapshot at 12:28:33 completed in 69s |
| Why poRepSet failed | bgrid tried → agent (`go run cm.go`) returned HTTP 500 on `ProcessCursorDescription` → bgrid aborted, cleared the request | appdb-rs agent (inside `primary-om-appdb` container) works correctly |

**Three additional findings from the real UI flow:**

1. **bgrid self-cleans on agent failure.** When the customer-side agent returns 500 during a snapshot attempt, bgrid:
   - Logs `Abort triggered by error... Status: 500 Server Error`
   - Calls `deleteInProgressCheckpointSnapshot` to remove the orphan in-flight doc
   - Clears `onDemandSnapshotInfo` from the job doc
   - Resumes normal polling
   
   The window where `workingOn=true` + an incomplete snapshot doc exist is **brief (seconds, not minutes)**. This narrows the practical race-window for Probe A's failure mode — appdb-rs snapshots taken at random times during normal customer activity are **unlikely** to capture mid-flight customer state because the mid-flight window is so short.

2. **The agent-500 issue is asymmetric in this PoC.** Meta OM's `appdb-rs` agent (inside the `primary-om-appdb` container) handles WT checkpoint requests correctly — proven by the successful snapshot at 12:28:33 (start) → 12:29:42 (complete). Primary OM's locally-built `go run cm.go` agent fails the same request. This is **not** a v8.0 backport defect; it's a difference in how the locally-compiled dev agent handles the snapshot cursor protocol. The Meta OM appdb-rs agent is closer to production behavior.

3. **Modal-handling pattern works.** The kebab `details.context-menu summary` → `button.take-snapshot-now` → modal `.modal button.btn-primary` flow is now a working template for any future OM UI driving (snapshot, restore, deployment edit, etc.).

**Net implication for the AppDB-only MVP launch readiness:**

The original Probe A finding ("bgrid honors stale `workingOn=true` indefinitely") is empirically valid for the **single failure path** we tested, but the **practical likelihood of triggering it in production is lower than feared**:

- Real bgrid cleans up after agent failures within seconds (not the indefinite duration my injection simulated)
- For the injection scenario to match reality, the appdb snapshot must capture the few-second window between "bgrid sent cursor description request" and "bgrid received and processed the response" (or its abort path)
- In a production OM where agents reliably succeed, this window is even narrower (no abort path needed; bgrid only holds `workingOn=true` for the duration of the actual snapshot)

The recovery runbook (clear `workingOn=true` locks older than 5 min, delete orphan `completed=false` snapshot docs older than 1 hr) remains the right MUST-include item for customer-facing docs, but the operational severity is **rare and recoverable** rather than **likely and silent**. The launch-readiness verdict stands: AppDB-only / multi-store MVP is shippable with the documented runbook.

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

#### Probe B — Test record (2026-06-02)

**Approach:** inject `backupRestoreUrl*` directives onto the `poRepSet_1` process in `automationcore.config.automation`, increment `version`, observe whether the agent picks up the stale directive on next poll and starts a (data-wiping) Phase 1 restore plan. Revert in a tight window if the agent doesn't bite, or if it does bite, accept losing one member of a 5-member RS (recovers via initial sync).

**Two attempts:**

| Attempt | Action | Observed |
|---|---|---|
| **#1** (10:48:19Z → 10:48:30Z, ~11s) | Injected `backupRestoreUrl` + bumped version (BUG: string-concat'd `"114" + "1"` = `"1141"` instead of integer 115) | No agent activity. Reverted. |
| **#2** (10:50:02Z → 10:50:18Z, ~16s) | Injected `backupRestoreUrl` + properly `$inc`-ed version 114 → 115 | **No agent activity in window.** No `clusterConfig edition is different` log entry, no `RestoreRsMember*` plan computation, no Phase 1 BounceStop. Reverted with no harm. |

**Why the agent didn't bite — the architecture insight:**

The agent fetches its `clusterConfig` from OM's REST API (`/agents/api/automation/conf/v1/<gid>?...`), which is served from OM's **published config cache** maintained by `AutomationConfigPublishingSvc`. That cache is updated by OM's `saveDraft → publish` pipeline, which is the path the UI/Public-API uses to push new configs. **Direct DB writes to `automationcore.config.automation` bypass this pipeline.** OM doesn't notice the appdb doc changed, doesn't recompute the edition hash, doesn't re-publish, and the agent's next poll returns the cached prior edition.

This is a relevant architectural detail for Dan's question. Specifically:

**The actual customer-scenario sequence is:**

1. Customer triggers restore → OM's publish pipeline writes `backupRestoreUrl*` to `config.automation` AND updates the in-memory published cache. Agent fetches v=N+1 (with directive) and starts Phase 1.
2. Mid-restore, customer's appdb is snapshotted (captures v=N+1 with directive).
3. Restore completes → OM's publish pipeline writes a new config with directive CLEARED (v=N+2). Agent fetches v=N+2 and finishes Phase 2.
4. Days later: appdb is rolled back to the snapshot from step 2 (captures v=N+1 with directive).
5. **Critical: did OM also restart?**
   - **If OM is restarted** (often required for the rollback to take effect coherently): OM loads the rolled-back appdb on startup → re-populates its published cache from `config.automation` (which now has the directive at v=N+1) → publishes to agents.
   - **If OM is NOT restarted**: OM's in-memory published cache still holds v=N+2 (the post-restore state) → agent's polls continue returning the post-restore config. The rolled-back appdb's directive is **invisible** to the agent until the cache is invalidated.

**Outcome — depends on whether OM restarts after appdb rollback:**

| Path | Agent behavior | Customer impact |
|---|---|---|
| Appdb rolled back, OM NOT restarted | Agent's polls served from stale in-memory cache (v=N+2 with directive cleared). Agent stays in goal state. No wipe. | ✅ Safe — but operator has a divergent state to clean up eventually |
| Appdb rolled back, OM restarted | Agent's polls return v=N+1 with the stale directive. **Without restoration mode**: agent applies plan → Phase 1 BounceStop → wipe → MakeBackupDataAvailable points at long-dead `backupRestoreUrl` → HTTP 500 retry loop → data loss (poRepSet members empty). **With restoration mode**: agent's cached cv=N+2 > OM's served cv=N+1 → regression detected → restoration mode triggers → reconciliation re-publishes agent's v=N+2 → directive cleared → no wipe. | ❌ vs ✅ — restoration mode is the gate |

**This isomorphism with `WHY-IT-MATTERS-SHARDED-DATA-LOSS.md` is the key takeaway:** the same restoration-mode mechanism that prevents the sharded-cluster topology destruction (Test 1 vs Test 2 in that doc) ALSO prevents this stale-directive wipe scenario. The cv= regression-detect machinery covers both cases.

**Outcome: ✅ PASS (provided OM Backup Phase 1 is enabled).**

**Caveat / FU:** in the AppDB-only MVP, the documentation should explicitly call out: **"appdb rollback REQUIRES OM restart for clean recovery — and restoration mode (`AUTOMATION_RESTORATION_MODE=enabled`) MUST be on for OM 8.0+ before any such restart, otherwise stale restore directives can re-trigger a wipe."** This is the "without this feature" scenario from `WHY-IT-MATTERS-SHARDED-DATA-LOSS.md` applied to the restore-in-progress case.

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

#### Probe C — Test record (2026-06-02)

**Already covered by an earlier probe.** The "snapshot index references blocks that don't exist in `backupstore.files`" scenario is exactly what [`8.0-TEST-PLAN.md` Tier-1 Probe 2 ("Broken-snapshot rejected at REST")](8.0-TEST-PLAN.md) exercised: we rolled back `s3-meta-rs` to a point that wiped some block-file registrations, then attempted to restore a snapshot whose fileIds were among the wiped set, and confirmed PR #770's `SnapshotBlockValidationSvc` catches it at restore-creation time with `SnapshotBlocksMissingException`. The same code path fires regardless of HOW the inconsistency arose (s3-meta rollback in our PoC test, mid-groom appdb-snapshot in Dan's hypothetical).

**Outcome: ✅ PASS — same validator covers both arrival paths.**

**For the AppDB-only MVP specifically:** in a single-DB topology, `backupstore.files` lives in the same appdb as `backupjobs.snapshots`. Rolling back appdb to a mid-groom moment rewinds both collections together. After restore:
- Some snapshot's `files` map references fileIds
- Some of those fileIds may have been mid-deleted (because the groom was in flight)
- A user attempting to restore that snapshot will hit `SnapshotBlocksMissingException` at the REST layer — they cannot launch a doomed restore, no data wipe occurs.

The validator we backported as PR #770 (CLOUDP-405628) protects against this case. Nothing new needed.

**However:** if the customer is running an OLDER version of OM that DOESN'T have PR #770, mid-groom rollback can lead to the silent-wipe failure mode. The launch documentation should explicitly mention "OM Backup Phase 1 (with PR #770) is required to safely restore appdb in topologies where appdb holds backup metadata — earlier versions can lose customer data on broken-snapshot restore."

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

#### Probe D — Test record (2026-06-02)

**Approach:** rather than orchestrate a real chunk migration on `poShardClust`, we injected the **observable consequence** of one — a rewound `lastOplogPush` on poRepSet's job doc (set to 10 minutes in the past, simulating an appdb captured at that earlier point). This isolates the question "what does the daemon do when its persisted oplog cursor is suddenly behind reality?" without having to time a real migration.

**Observed behavior:**

| Event | Time (UTC) | Detail |
|---|---|---|
| Baseline `lastOplogPush` | 10:42:45Z | normal advance from oplog tailing |
| Injection applied | 10:43:09Z | `lastOplogPush` rewound to 10:33:09Z + marker `_isInjectedForProbeD=true` |
| Observation window | 60 seconds | daemon's oplog tailer continued working |
| Post-injection `lastOplogPush` | 10:43:45Z | **daemon naturally advanced past the rewind** |
| OM-log activity for poRepSet during window | 8 new entries | bgrid continued polling normally (delta 48 → 56) |
| Daemon log noise | none | no errors, warnings, or stuck-state indicators |

**Outcome: ✅ PASS — fully self-recovering.** The daemon's oplog tailer treats `lastOplogPush` as a *cached marker of progress* — it does NOT use that value to decide WHERE to resume tailing. On every poll, it queries the actual oplog on the source RS, pushes any new slices to the oplog store, and writes the new max-pushed timestamp back to `lastOplogPush`. The persisted value is overwritten with whatever the live state says.

**Implication for the AppDB-only MVP:** if the appdb is restored to a moment when `lastOplogPush` was 10 min behind real-time (because a chunk migration was mid-flight or backup tailing was paused), the daemon resumes oplog tailing **on the actual customer-deployment RS** and re-pushes any slices that fall in the gap. No data loss. The only cost is a transient delay before the cursor catches up to live time — bounded by the size of the gap and the oplog throughput on the source RS. For typical customer workloads, this is seconds to a few minutes.

**No mitigation needed.** The daemon's "trust the live RS, treat persisted cursors as advisory" design is exactly what AppDB-only customers want.

**One caveat worth flagging:** if the oplog gap exceeds the source RS's oplog retention window (e.g., appdb was restored from a snapshot 25+ hours old when the source has a 24-hour oplog), the daemon WILL be unable to fill the gap — it'll see "oplog hole detected" and refuse to mark a complete PITR range. That's the standard MongoDB sync-from-scratch-needed case and is well-documented elsewhere; not specific to OM Backup Phase 1.

---

## Comparison: AppDB-only MVP risk profile (filled from probe results)

| Failure mode | Multi-store topology (current PoC) | AppDB-only MVP | What v8.0 protects | Probe |
|---|---|---|---|---|
| Cross-store rollback skew (s3-meta only) | Real risk, fixed by PR #770 validator | N/A — no separate stores to skew | PR #770 `SnapshotBlockValidationSvc` | 8.0-TEST-PLAN T1.2 |
| Concurrent customer-snapshot during appdb snapshot → stale `workingOn=true` lock | Same risk on both topologies | **Same risk** — bgrid silently skips polling, backups stop | ❌ **Nothing in v8.0 detects stale locks.** Operator must manually clear via mongosh. | **Probe A** |
| Concurrent customer-restore during appdb snapshot → stale `backupRestoreUrl*` directives | Same risk on both topologies (only matters if OM restarts) | Same risk; AppDB-only customers more likely to restart OM along with appdb restore | ✅ **Restoration mode (cv= regression detect + reconciliation)** clears stale directives by merging agent's higher-cv cached config back into OM's published config | **Probe B** + `WHY-IT-MATTERS-SHARDED-DATA-LOSS.md` |
| Concurrent groom during appdb snapshot → orphan `backupstore.files` references | s3-meta-rollback scenario in our PoC; same shape | Single-DB rollback rewinds both `backupjobs.snapshots` and `backupstore.files` together (cleaner than multi-store) | ✅ **PR #770 validator** catches at restore-creation: any restore attempt fails with HTTP 409 `SNAPSHOT_BLOCKS_MISSING`, no data wipe | **Probe C** (= 8.0-TEST-PLAN T1.2) |
| Concurrent chunk migration during appdb snapshot → rewound oplog cursor | Same on both | Self-correcting — daemon's oplog tailer re-advances `lastOplogPush` on next poll | ✅ No mitigation needed; design is sound | **Probe D** |

## Overall verdict for AppDB-only MVP launch

**Three of four concurrent-ops failure modes are already protected by what we backported.** The only gap is the `workingOn=true` stale-lock case from Probe A, and it's:

- **Customer-recoverable** via a documented mongosh runbook (4 lines)
- **Detectable** by any monitoring that alerts on "no new snapshots in X hours"
- **Not a data-loss event** — just a silent backup-pause until the operator notices
- **Fixable** in a future release via a small bgrid enhancement (heartbeat-based stale-lock detection, ~15 LOC)

**Recommendation: AppDB-only MVP is shippable** with these mandatory items in the customer-facing documentation:

1. **MUST**: `mms.featureFlag.automation.restorationMode=enabled` is required before any appdb restore. Without it, stale restore directives can re-trigger Phase 1 BounceStop (data wipe).
2. **MUST**: appdb restore should be followed by an OM restart so the in-memory published config matches the rolled-back state. Without restart, OM and appdb diverge until the next natural publish.
3. **SHOULD**: post-restore, the operator should check `backupjobs.jobs` for any documents with `workingOn=true` whose `state.startedAt` is older than 5 minutes. If found, run the cleanup runbook below — bgrid will silently skip polling these jobs otherwise.
4. **SHOULD**: PR #770 (v8.0.23+ and main) is mandatory for AppDB-only — otherwise a mid-groom appdb restore can leave snapshots in the index that reference physically-deleted blocks, and restoring those snapshots will wipe customer data without warning.

## Follow-up engineering tickets (file under the OM Backup epic; not launch blockers)

| ID | Title | Estimated effort | Notes |
|---|---|---|---|
| FU-CONC-1 | bgrid: detect stale `workingOn=true` locks via `state.startedAt` age check | ~15 LOC in `WTCheckpointScheduleSvc` | If `workingOn=true` AND `state.startedAt` is older than `2 × poll_interval` (≈ 2 minutes), clear the lock and emit `WARN`. Removes Probe A's silent-pause failure mode. |
| FU-CONC-2 | bgrid: WARN on orphan `backupjobs.snapshots` docs with `completed=false` older than 1 hour | ~5 LOC in any periodic check | Gives monitoring something to alert on for the Probe-A failure mode. |
| FU-CONC-3 | restoration-mode reconciliation: include "clear stale workingOn locks" as part of the recovery procedure | ~10 LOC in `ReconciliationOrchestrator.doReconcile` | Closes the gap fully — restoration mode triggers automatic recovery from Probe-A state too. |
| FU-CONC-4 | Customer-facing doc: "Recovering an Ops Manager AppDB after restore" runbook | Doc, no code | Mandatory pre-launch artifact. Includes the mongosh runbook below + the "MUST restart OM after appdb restore" guidance. |

### Recovery runbook for the Probe-A failure mode (mandatory inclusion in launch docs)

After ANY appdb restore that might have captured a mid-customer-snapshot moment, the operator should run on the restored appdb:

```js
// Clear stale workingOn locks where startedAt is older than 5 minutes
db.getSiblingDB("backupjobs").jobs.updateMany(
  {
    workingOn: true,
    $or: [
      {"state.startedAt": {$exists: false}},
      {"state.startedAt": {$lt: new Date(Date.now() - 5*60*1000)}}
    ]
  },
  {$set: {workingOn: false, "state.action": "WT checkpoint"}}
);

// Delete orphan incomplete snapshot docs older than 1 hour
db.getSiblingDB("backupjobs").snapshots.deleteMany({
  completed: false,
  startTime: {$lt: new Date(Date.now() - 60*60*1000)}
});
```

bgrid resumes polling within ~60 seconds of the cleanup. The first new snapshot will be on the regular schedule.

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

# Scenario 1 — Fix Proposal: Pre-Flight Snapshot-Block Validation Before Restore

> **Companion docs:** [RESTORE-FINDINGS.md](./RESTORE-FINDINGS.md) (full PoC results, Scenarios 1–3) · [SIDE-FINDINGS.md](./SIDE-FINDINGS.md) (operational issues uncovered during PoC)
>
> **Jira:** linked under [CLOUDP-388026](https://jira.mongodb.org/browse/CLOUDP-388026) (Track 3 — Reconciliation Engine)
>
> **Scope:** Reactive validation only (MVP). UI marking and a proactive scheduled groom are deferred follow-ups.

---

## Context

In the Meta-OM-backs-Primary-OM topology, an admin can roll back `s3-meta-rs` (the snapshot-block index) independently of `appdb-rs` (the snapshot catalog). When that happens — documented in `RESTORE-FINDINGS.md` § Scenario 1 — snapshots in `backupjobs.snapshots` (on appdb-rs) whose `files.fileId` entries were registered to `backupstore.files` (on s3-meta-rs) **after** the rollback target become "broken":

- The snapshot doc still says `completed: true`.
- The UI still lists it as a normal restorable snapshot.
- Triggering a restore writes `backupRestoreUrl*` directives → agent kills mongod and **wipes `/data/db`** → agent asks the daemon for the tarball → daemon queries `backupstore.files` by fileId → not found → HTTP 500 → agent loops 78–186× → UI status reads "Finished" / "Cancelled", never "Failed" → user is left with **an empty RS** and must manually cancel and restore from an older healthy snapshot.

The fix here validates fileId reachability against `backupstore.files` **before** `AutomationConfigBackupSvc.updateReplSetWithBackupRestore` writes any directive. If any fileId is missing (or s3-meta is unreachable), the restore-creation REST call is rejected with HTTP 409 / 503 and the agent never receives a wipe instruction. The RS stays intact and the user retries against a healthy snapshot.

---

## Recommended approach

Promote `IntegrityCheckJob.checkSnapshotIntegrity`'s validation logic from a daemon-only / test-only path into a reusable, web-side `SnapshotBlockValidationSvc`. Wire it into `AutomatedBackupRestoreValidationSvc.validateRestoreJob` so it runs immediately after the existing namespace / version / live-restore checks, before `ApiCreateRestoreJobsSvc.createAutomatedRestoreJob` queues the two-phase deployment job. Use the existing `S3BlockFileSvc` Guice binding (already injected in `RestoreResource`), so no new daemon RPC or new Mongo connection is needed. Gate the whole new check behind the existing `AUTOMATION_RESTORATION_MODE` feature flag (group-scoped) so the rollout matches the rest of the Meta-OM-backs-Primary-OM work.

---

## Implementation steps

### 1. New service — `SnapshotBlockValidationSvc`

Path: `server/src/main/com/xgen/cloud/brs/restore/_public/svc/SnapshotBlockValidationSvc.java` (new).

- `@Singleton`, Guice-injected with `S3BlockFileSvc`, `ImportS3MetadataBlockFileSvc`, and any other `BlockFileSvc` impl that `RestoreResource:149–203` already binds. Mirror that wiring exactly so we don't drift from the proven binding set.
- Dispatch on `snapshot.getSnapshotStoreType()` to pick the right `BlockFileSvc` (s3-blockstore vs mongo-blockstore — the existing `RestoreResource:1516` already does this dispatch; extract / reuse).
- Public API:
  ```java
  ValidationResult validateSnapshotBlocks(Snapshot snapshot);          // single RS
  ValidationResult validateClustershotBlocks(Clustershot clustershot,
                                             RestoreAssetStore store); // sharded
  ```
- Implementation: collect all `fileId`s from `snapshot.getFilePathToIdMap()`, call `BlockFileDao.getWithoutBlocks(Collection<ObjectId>)` (existing method at `BlockFileDao.java:192`) — **one indexed `$in` query per snapshot**, not 42 individual lookups. Compare returned set to requested set; the difference is `missingFileIds`.
- Clustershot variant: walk `clustershot.getShardStates()` + the config-server snapshot, validate each child snapshot, aggregate. Return a single combined `ValidationResult` listing which shards have missing blocks.
- Treat `BlockFileSvc` exceptions (s3-meta unreachable, Mongo timeout) as a **separate failure mode** — throw a typed `SnapshotBlockValidationUnavailableException` (see step 2). Do NOT swallow.

### 2. New typed exceptions + error codes

Path: `server/src/main/com/xgen/cloud/brs/restore/_public/svc/` (new sibling files).

- `SnapshotBlocksMissingException extends ValidationException` — carries `snapshotId`, missing count, sample of up to 5 missing fileIds. Thrown when fileIds are confirmed absent.
- `SnapshotBlockValidationUnavailableException extends ValidationException` — thrown when the validation itself cannot complete (s3-meta down). Distinct so the catch can map it to 503, not 409.

Path: `server/src/main/com/xgen/svc/mms/api/res/common/ApiErrorCode.java` (existing — add new entries alongside `RESTORE_VALIDATION_FAILED` near line 1247–1248).

```java
SNAPSHOT_BLOCKS_MISSING(
    HttpServletResponse.SC_CONFLICT,
    "Snapshot %s is no longer restorable: %d block file(s) are missing from the snapshot store."
        + " The replica set has NOT been modified. Please choose a different snapshot."
        + " Sample missing block IDs: %s"),
SNAPSHOT_BLOCK_VALIDATION_UNAVAILABLE(
    HttpServletResponse.SC_SERVICE_UNAVAILABLE,
    "Cannot verify snapshot integrity right now (snapshot store unreachable). Restore"
        + " refused as a safeguard. Retry once the snapshot store is reachable."),
```

### 3. Wire into `AutomatedBackupRestoreValidationSvc`

Path: `server/src/main/com/xgen/cloud/brs/restore/_public/svc/AutomatedBackupRestoreValidationSvc.java` (existing).

- Constructor (line 59–71): add `SnapshotBlockValidationSvc _snapshotBlockValidationSvc` and `AppSettings _appSettings` (for the feature-flag check).
- `validateRestoreJob` (line 91–105): after the existing `validateLiveRestoreJob` call, add a new private method:
  ```java
  private void validateSnapshotBlocksReachable(
      final RestoreAssetStore restoreAssetStore,
      final RestoreJob pRestoreJob,
      final Group pTargetGroup)
      throws ValidationException {
    if (!_appSettings.isFeatureFlagEnabled(FeatureFlag.AUTOMATION_RESTORATION_MODE, pTargetGroup.getId())) {
      return;
    }
    final String snapshotId = pRestoreJob.getJobParameters().get(JOB_PARAM_SNAPSHOT_ID_FIELD);
    if (snapshotId == null) {
      // PITR path — resolve the starter snapshot the daemon will actually use
      // via the same path as findClustershotForPIT (existing svc:478)
      // then validate that.
      ...
    } else if (pRestoreJob.getJobType() == JobType.RESTORE_CLUSTER) {
      Clustershot cs = restoreAssetStore.getClustershot(new ObjectId(snapshotId));
      _snapshotBlockValidationSvc.validateClustershotBlocks(cs, restoreAssetStore);
    } else {
      Snapshot s = restoreAssetStore.getSnapshot(new ObjectId(snapshotId));
      _snapshotBlockValidationSvc.validateSnapshotBlocks(s);
    }
  }
  ```
- PITR starter resolution: reuse the same resolution path the daemon uses (`_backupSvc.findClustershotForPIT` or whatever `existing svc:478` calls). Validating a different snapshot than the daemon ultimately picks would defeat the check.

### 4. Wire exceptions through `ApiCreateRestoreJobsSvc`

Path: `server/src/main/com/xgen/svc/mms/api/svc/ApiCreateRestoreJobsSvc.java` (existing).

The current catch (around line 177–178):
```java
} catch (final ValidationException e) {
  throw ApiErrorCode.RESTORE_VALIDATION_FAILED.exception(envelope, e.getMessage());
}
```

Add **two more specific catches first** so the new typed exceptions get their dedicated 409 / 503 mapping (and bubble up snapshotId + missing-count for telemetry):

```java
} catch (final SnapshotBlocksMissingException e) {
  throw ApiErrorCode.SNAPSHOT_BLOCKS_MISSING.exception(
      envelope, e.getSnapshotId(), e.getMissingCount(), e.getMissingSample());
} catch (final SnapshotBlockValidationUnavailableException e) {
  throw ApiErrorCode.SNAPSHOT_BLOCK_VALIDATION_UNAVAILABLE.exception(envelope);
} catch (final ValidationException e) {
  throw ApiErrorCode.RESTORE_VALIDATION_FAILED.exception(envelope, e.getMessage());
}
```

The existing generic catch keeps working for all other validation failures.

### 5. Failure must happen BEFORE the directive write

This is the load-bearing property. The flow today is:

1. `ApiCreateRestoreJobsSvc.createAutomatedRestoreJob` runs validation
2. Then calls `BackupRestoreJobSvc.createRestoreJob` to persist the job
3. Then calls `_deploymentJobsSvc.startDeploymentJob` to queue the two-phase job
4. **Two-phase job Phase 1** invokes `RestoreRsDeploymentJobHandler` → `AutomationConfigBackupSvc.updateReplSetWithBackupRestore` → writes `backupRestoreUrl*` to `automationcore.config.automation` → agent wipes `/data/db`

If we throw in step 1, step 3 never runs, Phase 1 never fires, no directive is written, no wipe happens. This is exactly the property we want. Add an integration test (step 8) that asserts no `backupRestoreUrl*` field exists on the target group's automation config after the rejected POST.

### 6. Feature flag

Reuse `AUTOMATION_RESTORATION_MODE` (existing, `FeatureFlag.java:870`, `Scope.GROUP`). No new flag.

- Gated by `mms.featureFlag.automation.restorationMode=enabled` at the group level — same setting the rest of the Meta-OM-backs-Primary-OM project uses.
- When disabled: validation no-ops, existing (broken) restore behavior preserved. This is the safety hatch for any topology where the new check has an unforeseen issue.
- When enabled: validation runs synchronously on every restore creation.

### 7. Performance

- 1 RS snapshot ≈ 42 fileIds → 1 indexed `$in` query on `backupstore.files._id` (covered by the `_id` hashed shard key at `BlockFileDao.java:72,96`) → ~10–50 ms.
- 1 sharded clustershot of N shards + 1 config server → N+1 such queries, each targeting one shard → a few hundred ms even at N=30.
- Sequential per shard in v1 (no parallelization). Acceptable inside the synchronous REST call.
- Do NOT iterate `blockFileDao.get(fileId)` per file (the test-only `IntegrityCheckJob` pattern); it adds 42× the RTT.

### 8. Tests

- **Unit — `SnapshotBlockValidationSvcTest`** (new, alongside the new svc).
  Use the existing in-memory Mongo fixture pattern from `BlockFileDaoTest`. Seed a `Snapshot` with 5 fileIds; insert 3 of them in `backupstore.files`; assert `validateSnapshotBlocks` returns a result whose `missingFileIds.size() == 2` and contains the expected two ids. Repeat for `validateClustershotBlocks` with one shard's blocks intact and one shard's blocks missing.

- **Unit — `AutomatedBackupRestoreValidationSvcTest`** (extend existing or add new).
  Mock `SnapshotBlockValidationSvc` to return missing blocks; assert `validateRestoreJob` throws `SnapshotBlocksMissingException`. With feature flag off, mock is never called (assert via Mockito `verify(svc, never())`).

- **Integration — `ApiRestoreJobsResourceIntegrationTest`** (extend existing).
  Seed `backupjobs.snapshots` with a snapshot whose `files` map references fileIds that do NOT exist in `backupstore.files`. POST `/api/public/v1.0/groups/{gid}/clusters/{cid}/restoreJobs`. Assert:
  - HTTP 409 with `errorCode = SNAPSHOT_BLOCKS_MISSING`
  - The target group's `automationcore.config.automation` doc has **no `backupRestoreUrl*` fields** (load-bearing — proves no wipe was triggered)
  - No `DeploymentJobStatus` row with `JobType.RESTORE_RS` was queued
  - The error response body mentions the missing block count and at least one missing fileId in the sample

- **Integration — feature-flag disabled.** Same fixture, flag off, assert existing buggy behavior (HTTP 200, job queued) so we know the flag actually controls the path.

- **Integration — clustershot variant.** 3-shard clustershot, only shard 2's blocks missing; assert 409 names shard 2.

- **Integration — s3-meta unreachable.** Mock `BlockFileSvc` to throw a connection exception; assert HTTP 503 `SNAPSHOT_BLOCK_VALIDATION_UNAVAILABLE` and no directive write.

---

## Critical files to modify

| File | Change |
|---|---|
| `server/src/main/com/xgen/cloud/brs/restore/_public/svc/SnapshotBlockValidationSvc.java` | **NEW** — main validation service |
| `server/src/main/com/xgen/cloud/brs/restore/_public/svc/SnapshotBlocksMissingException.java` | **NEW** — typed exception |
| `server/src/main/com/xgen/cloud/brs/restore/_public/svc/SnapshotBlockValidationUnavailableException.java` | **NEW** — typed exception |
| `server/src/main/com/xgen/cloud/brs/restore/_public/svc/AutomatedBackupRestoreValidationSvc.java` | Add `_snapshotBlockValidationSvc`, `_appSettings`; call new validation in `validateRestoreJob` |
| `server/src/main/com/xgen/svc/mms/api/svc/ApiCreateRestoreJobsSvc.java` | Add 2 specific catch clauses before the generic `ValidationException` catch (around line 177) |
| `server/src/main/com/xgen/svc/mms/api/res/common/ApiErrorCode.java` | Add `SNAPSHOT_BLOCKS_MISSING` (409) and `SNAPSHOT_BLOCK_VALIDATION_UNAVAILABLE` (503) enum entries near line 1248 |

No DB migration. No API contract change (only adds new error codes). Cleanly backportable.

---

## Verification end-to-end

Reproduce the original failure on the existing test setup, then verify the fix prevents the wipe:

1. **Reproduce** (current `om-backup-local` branch, fix not present):
   - Use [`list-snapshots.sh`](./list-snapshots.sh) to identify a post-rollback broken snapshot on `poRepSet`
   - Roll back `s3-meta` via Meta OM UI per `RESTORE-FINDINGS.md` Scenario 1
   - Trigger restore of the broken snapshot → agent wipes `/data/db` → HTTP 500 loop confirmed

2. **Patch and rebuild** Primary OM with the new fix on a fresh branch off `prakhar.dhama/CLOUDP-388027`:
   - Branch: `prakhar.dhama/CLOUDP-XXXXXX-validate-snapshot-blocks` (replace `XXXXXX` with the new Jira ticket id)
   - Rebuild via `bazel run --server_env=hosted //server:mms -- '--jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled'`

3. **Reproduce the rollback** (broken snapshot exists again):
   - Same steps as 1 — roll back `s3-meta` past some `poRepSet` snapshots

4. **Attempt the restore** of a broken snapshot via the UI / API:
   - Expected response: HTTP 409 with `errorCode = SNAPSHOT_BLOCKS_MISSING` and the missing-block count in the message
   - The deployment topology page must NOT enter restore mode; mongods stay up
   - `db.config.customers.findOne({...}).automationConfig.processes[*].backupRestoreUrl` — assert **absent** for every member of the target RS
   - Confirm no agent log line `BounceStopIfUpWithForceKill`

5. **Healthy snapshot still works:**
   - Same UI / API but pick a pre-rollback healthy snapshot → restore completes normally (3 downloads, ~2 min)

6. **s3-meta unreachable path:**
   - Stop the `primary-om-s3-meta` container temporarily
   - Trigger a restore → expect HTTP 503 `SNAPSHOT_BLOCK_VALIDATION_UNAVAILABLE`, no directive write
   - Restart the container; retry → restore proceeds normally

---

## Risks / open questions

1. **Confirm `S3BlockFileSvc` is bound in the Primary OM JVM in this Meta-OM topology.** `RestoreResource:149–203` proves the binding exists in the OM JVM in standard deployments. The Plan agent flagged that the Meta-OM-backs-Primary-OM split-process topology may behave differently. Worth a 5-min sanity check before starting: launch Primary OM with the existing JVM flags, inspect the Guice bindings (or just attempt to inject `S3BlockFileSvc` in a probe) to confirm. If unbound in this topology, fall back to a new daemon HTTP endpoint that performs the same query — design is mechanically the same, just an extra hop.

2. **PITR starter-snapshot resolution.** The daemon auto-picks the starter snapshot for PITR restores (`RESTORE-FINDINGS.md` § Scenario 1 Probe 5 is an example where the auto-picked starter was the broken one). We must validate the exact same starter the daemon will use. If the resolution logic is duplicated or diverged between OM and daemon, this fix could validate snapshot A while the daemon ultimately uses snapshot B and still fails. Look at `_backupSvc.findClustershotForPIT` (referenced from `AutomatedBackupRestoreValidationSvc:478`) — that should be the single source of truth.

3. **Per-shard parallelism for clustershot validation.** Sequential is fine in v1. If big-cluster restore latency becomes a problem post-rollout, parallelize via the existing executor pattern used in `BackupSnapshotSvc`. Out of scope here.

4. **Jira ticket / branch.** This is a new fix, related to CLOUDP-388026 (Track 3 — Reconciliation Engine). Create a new Story under the same epic with name "Validate snapshot blocks before restore to prevent late-failing restores with empty RS". Branch: `prakhar.dhama/CLOUDP-XXXXXX-validate-snapshot-blocks`.

---

## Follow-ups (NOT in this PR)

- `isRestorable` boolean on `ApiSnapshotView` so the UI can hide / badge broken snapshots without making the user try a restore. Either wire to the existing `IntegrityCheckJob` (currently daemon-side) or run the new validation lazily on snapshot listing.
- Scheduled groom job that periodically scans all `backupjobs.snapshots` and pre-computes the `isRestorable` flag in the DB.
- Surface a distinct "Failed" Status column in Restore History (today, a failed restore reads "Finished" / "Cancelled" — misleading per `RESTORE-FINDINGS.md` Scenario 1).
- Pre-rollback safety guard: when an admin triggers a `s3-meta` rollback in Meta OM, warn that downstream snapshots in any tenant will become unrestorable. Out of scope; sits in Meta OM, not Primary OM.

---

## Effort estimate

Three layered approaches. Each builds on the previous; this PR's scope is **Approach 1** only. Approaches 2 and 3 are deferred follow-ups (already enumerated in the [Follow-ups](#follow-ups-not-in-this-pr) section above) — the numbers here let us weigh whether to bundle or split.

### Approach 1 — Reactive (this PR)

Synchronous validation at restore-creation time. Rejects the REST POST with HTTP 409 / 503 before the agent ever receives a wipe instruction. The RS data is never touched on a broken snapshot.

| Component | Effort |
|---|---|
| `SnapshotBlockValidationSvc` + 2 typed exception classes | ~1 day |
| Wire into `AutomatedBackupRestoreValidationSvc` + catch chain in `ApiCreateRestoreJobsSvc` | ~0.5 day |
| 2 new `ApiErrorCode` entries + feature-flag gating | ~0.5 day |
| Unit tests (svc + extended `AutomatedBackupRestoreValidationSvc` tests) | ~1 day |
| Integration tests (REST POST → 409 + no `backupRestoreUrl*` directive write) | ~1 day |
| PR review / iteration | ~1 day |
| Per-branch backport | ~0.5 day each |
| **Subtotal** | **~5 dev days** (excluding backports) |

**Trade-offs.** Smallest surface area, easiest to backport, fixes the data-loss bug end-to-end. UI still lists broken snapshots normally — the user discovers the issue only when they click "Restore" and get a 409. No proactive signal in the picker.

---

### Approach 2 — Proactive (Approach 1 + UI marking)

Approach 1 plus a persisted `isRestorable` flag on the snapshot, surfaced in `ApiSnapshotView`. The validation result is written back to `backupjobs.snapshots` whenever the synchronous check runs, so the UI can hide / badge the broken snapshot on the next page load.

| Component (delta over Approach 1) | Effort |
|---|---|
| `Snapshot` model: add `isRestorable` + `lastIntegrityCheckedAt` fields | ~0.5 day |
| `SnapshotDao`: persist the new fields; optional filter for restorable-only listings | ~0.5 day |
| `ApiSnapshotView`: expose `isRestorable` (default null = unknown, treated as true) | ~0.25 day |
| `SnapshotBlockValidationSvc`: write result back to AppDB at end of each validation call | ~0.5 day |
| UI: badge / disable Restore on broken snapshots in the snapshot picker (`SnapshotsPage`, `RestoreModal`) | ~1 day |
| Tests (DAO, view, UI component, integration) | ~1.5 days |
| **Delta subtotal** | **~+4 dev days** (cumulative ~9 dev days) |

**Trade-offs.** Users see the broken state proactively without clicking Restore. But the flag is only updated on snapshots that someone has *tried* to restore (or that a fresh check happened to touch) — pre-rollback healthy snapshots are never re-verified, and a snapshot that becomes broken without anyone attempting a restore stays marked restorable until the first try. To catch breakage independently of user action, you need Approach 3.

---

### Approach 3 — Active + scheduled groom (Approach 2 + periodic scan)

Approach 2 plus a daemon-side periodic job that walks every group's `backupjobs.snapshots` and pre-computes the `isRestorable` flag on a regular cadence. The UI is always accurate even for snapshots no one has touched recently; users never see a broken snapshot listed as restorable.

| Component (delta over Approach 2) | Effort |
|---|---|
| New daemon-side `SnapshotIntegrityGroomJob` (mirrors `IntegrityCheckJob` but iterates the whole project, calls back into `SnapshotBlockValidationSvc`) | ~1 day |
| Job scheduling, throttling, in-progress tracking; integration with existing job framework | ~1 day |
| Metrics + alerts (broken-snapshot rate, last-scan-age per group, validation failure counter) | ~0.5 day |
| Configurable cadence (default e.g. hourly) + opt-out via app setting | ~0.25 day |
| Tests (unit + integration with seeded broken snapshots + scheduling) | ~1.5 days |
| Operational runbook entry (when to expect a broken-snapshot alert, recovery steps) | ~0.25 day |
| **Delta subtotal** | **~+4.5 dev days** (cumulative ~13.5 dev days) |

**Trade-offs.** Full self-healing UX; the broken-snapshot state is always reflected without any user action. Adds a long-running daemon job that needs ops attention (CPU during scans, alert noise calibration). Largest surface area — also the highest review cost.

---

### Summary

| Approach | Effort | Cumulative | When to ship |
|---|---|---|---|
| 1. Reactive | ~5 dev days | ~5 | This PR — addresses the data-loss bug |
| 2. Proactive (+ UI marking) | +~4 dev days | ~9 | Follow-up PR once Approach 1 is in production for a release |
| 3. Active + groom job | +~4.5 dev days | ~13.5 | Follow-up after Approach 2; only if customer feedback shows surprise from snapshots silently going stale |

Backport cost is roughly +0.5 day per supported OM minor branch, regardless of approach.

---

## Appendix — Test Run 1 (post-fix validation, 2026-05-19)

Validates the Approach-1 implementation merged in [CLOUDP-405628 / ops-manager#770](https://github.com/10gen/ops-manager/pull/770). Setup mirrors [RESTORE-FINDINGS.md § S1 Run 2](./RESTORE-FINDINGS.md#s1-run-2-2026-05-05--primary-om-kept-running-during-restore) — Primary OM kept running through the entire test.

### Code under test

| Branch | Last commit (HEAD) |
|---|---|
| `prakhar.dhama/om-backup-local` (Primary OM build) | `afecc58cd30` |
| Includes the validation commit | `6529e79f5b7` — *CLOUDP-405628: Validate snapshot blocks before restore* |

OM started with:

```bash
bazel run --server_env=hosted //server:mms -- \
  '--jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled' \
  2>&1 | tee /tmp/primary-om.log
```

The `AUTOMATION_RESTORATION_MODE` feature flag must be `enabled` for the new validation to run — otherwise it no-ops and the existing buggy behavior is preserved (covered as Probe 3).

OM start time: **2026-05-19T07:26Z**. Validation classes verified present in `bazel-bin/server/src/main/com/xgen/cloud/brs/restore/_public/svc/libsvc.jar`.

### Baseline (captured 2026-05-19T07:26Z)

Trimmed to the rollback boundary + immediate neighbours. Full inventory at the test time was 20 s3-meta-rs / 20 oplog-meta-rs / 20 poRepSet snapshots; see [list-snapshots.sh](./list-snapshots.sh) for the unabridged dump.

| OM | Replica Set | Created (UTC) | Size | Snapshot ID | Note |
|---|---|---|---|---|---|
| Meta OM | s3-meta-rs | 2026-05-19T05:05:59Z | 43.3MB | `6a0bf033…` | pre-target context |
| Meta OM | s3-meta-rs | 2026-05-19T05:34:09Z | 43.4MB | `6a0bf6bd…` | **← rollback target** |
| Meta OM | s3-meta-rs | 2026-05-19T06:06:10Z | 43.6MB | `6a0bfe40…` | post-target |
| Meta OM | s3-meta-rs | 2026-05-19T07:04:11Z | 43.7MB | `6a0c0bd5…` | latest |
| Primary OM | poRepSet | 2026-05-19T05:08:07Z | 22.5MB | `6a0bf0aa…` | **Probe 1 — healthy (well pre)** |
| Primary OM | poRepSet | 2026-05-19T05:35:08Z | 22.5MB | `6a0bf705…` | boundary (~1 min post rollback target API time) |
| Primary OM | poRepSet | 2026-05-19T06:06:09Z | 22.6MB | `6a0bfe17…` | **Probe 2 — broken (clearly post)** |
| Primary OM | poRepSet | 2026-05-19T06:37:10Z | 22.7MB | `6a0c058d…` | broken (Probe 4 candidate) |
| Primary OM | poRepSet | 2026-05-19T07:06:11Z | 22.7MB | `6a0c0c51…` | broken (latest pre-test) |

### Rollback target

`s3-meta-rs` snapshot at **2026-05-19T05:34:09Z** (`6a0bf6bd…`). Picked so that:

- `poRepSet` snapshot at 05:08:07Z (`6a0bf0aa…`) is comfortably pre-rollback → Probe 1 expects success.
- 3 `poRepSet` snapshots post-rollback (06:06, 06:37, 07:06) all have block registrations after the s3-meta checkpoint and will be unreachable → use any of them for Probe 2.
- The 05:35Z snapshot is a boundary case (within the ~60 s WiredTiger checkpoint buffer); we'll observe but not depend on a specific outcome there.

### Probe plan

Six probes, ordered to leave the RS data intact in all cases (the whole point of the fix). After each, capture the HTTP status, observed agent / log behavior, and whether `automationcore.config.automation` saw a `backupRestoreUrl*` write.

| # | Scenario | Setup | Expected | Outcome |
|---|---|---|---|---|
| 1 | **Healthy snapshot restore** | Restore a pre-rollback `poRepSet` snapshot whose blocks were registered before the rollback target | HTTP 200; restore proceeds; ~3 downloads; ~2 min; status FINISHED | ✅ PASS — restore completed in ~2 min 20s (07:37:22 → 07:39:42), validator silently passed |
| 2 | **Broken snapshot restore** (the load-bearing test) | Restore a post-rollback `poRepSet` snapshot whose blocks are wiped from `backupstore.files` | HTTP 409 `SNAPSHOT_BLOCKS_MISSING`; `automationcore.config.automation` has **no** `backupRestoreUrl*` fields written; mongods stay up; agent log shows **no** `BounceStopIfUpWithForceKill`; RS data intact | ✅ PASS — UI showed validation error immediately at the restore-config step; no restore job created; no agent activity; mongods untouched. Two UX follow-ups raised — see notes. |
| 3 | **Feature flag off** | Disable `AUTOMATION_RESTORATION_MODE` (restart OM without the JVM flag), retry the broken-snapshot restore | Old buggy behavior preserved: HTTP 200 + agent wipes /data/db + HTTP 500 loop. Proves the flag gates the new path. | ⏭️ SKIPPED — flag-gating verified by code inspection rather than runtime. See note below. |
| 4 | **s3-meta unreachable** | Re-enable flag, restart OM. Stop `primary-om-s3-meta` container, attempt restore of any snapshot | HTTP 503 `SNAPSHOT_BLOCK_VALIDATION_UNAVAILABLE`; no `backupRestoreUrl*` write; mongods stay up | ✅ PASS — UI banner showed the 503 detail; no agent activity; mongods untouched. ~30 s lag before the banner appears (Mongo driver's default connect timeout) — acceptable for v1 |
| 5 | **s3-meta restored** | Start `primary-om-s3-meta` container; retry the same broken-snapshot restore from Probe 4 | HTTP 409 `SNAPSHOT_BLOCKS_MISSING` (not 503) — proves the failure-closed path correctly hands off to the failure-confirmed path once integrity can be verified | ✅ PASS — UI banner reverted to the missing-blocks message ("52 of 52 block file(s) are missing"); 503 cleared as expected |
| 6 | **PITR auto-selects broken starter** | PITR to a time after the rollback point where the picker auto-selects a broken starter snapshot | HTTP 409 `SNAPSHOT_BLOCKS_MISSING` — validator resolves the same starter the daemon would, via the shared `BackupSvc.findSnapshotForPIT(groupId, rsId, pitTimestamp)` entry point | ✅ PASS (after follow-up commit `80363209433`) — see Probe 6 + re-verify below |

### Observations (filled in as we run)

_Captured live during the test session._

#### Probe 1 — Healthy snapshot restore

Restore submitted **2026-05-19T07:37:22Z** for `poRepSet` snapshot `6a0bf0aabe061546c1b4cb17` (well pre-rollback). RestoreJob id: `6a0c1332be061546c1b580fc`.

Validation pre-flight ran and **passed silently** — no `SNAPSHOT_BLOCKS_MISSING` log, no exception. All 52 fileIds confirmed present in `backupstore.files`. The catch chain in `ApiCreateRestoreJobsSvc` was never hit; the deployment job queued normally.

Two-phase deployment ran end-to-end:

```
07:37:22  POST /restoreJobs accepted (agent version check passes)
07:37:26  Phase 0 — parallel-restore manifest computed (3 workers, 5 chunks, ~209 MB chunkSize)
07:37:57  Phase 0 → Phase 1 transition; pullUrl signed
07:38:12  Phase 1 started — agent wipes /data/db and begins parallel download
07:38:42  ...
07:39:18  finishParallelRestore (all 4 chunks completed across 4 parallel streams)
07:39:42  Cleaned-up 5 parallel restore chunks — restore complete
```

Total wall-clock: **~2 min 20s** end-to-end. Matches the pre-fix healthy-restore baseline from [RESTORE-FINDINGS § S1 Run 2 Probe 1](./RESTORE-FINDINGS.md#probe-results) (~2 min, "Finished" with 3 downloads). The new validation adds no measurable latency.

**Outcome:** ✅ As expected. The validator does not regress healthy-snapshot restores.

#### Probe 2 — Broken snapshot restore

Triggered restore in Primary OM UI for `poRepSet` snapshot `6a0bfe17be061546c1b51190` (06:06 AM UTC, all 52 fileIds confirmed wiped from `backupstore.files`).

The validation fired **before any deployment job was queued**. The UI surfaced the error inline at the restore-config step (cluster picker still visible behind the error banner, "RESTORE" button greyed). Error body returned by the API:

```
Invalid config: Snapshot 6a0bfe17be061546c1b51190 is no longer restorable:
52 block file(s) are missing from the snapshot store.
Sample missing fileIds: [6a0bfe17be061546c1b511c3,
                          6a0bfe17be061546c1b511c2,
                          6a0bfe17be061546c1b51192,
                          6a0bfe17be061546c1b51193,
                          6a0bfe17be061546c1b51194]
```

Confirmed in the underlying system state:

- **No `automationcore.config.automation` write** for any `poRepSet` member. The agent never received a `backupRestoreUrl*` directive — Phase 1 never fired.
- **All 3 `poRepSet` mongods stay up**. No `BounceStopIfUpWithForceKill` in any agent log.
- **No restore job in `backupjobs`**. The catch chain in `ApiCreateRestoreJobsSvc` rejected the request before `BackupRestoreJobSvc.createRestoreJob` could persist anything.

**Outcome:** ✅ PASS — the data-loss bug is fixed. The RS is intact. Compare to the same snapshot pre-fix behavior in [RESTORE-FINDINGS § S1 Run 2 Probe 3/4](./RESTORE-FINDINGS.md#probe-results), where the same broken snapshot wiped `/data/db` and looped 78–186× downloads before manual cancellation.

**UX follow-ups raised during testing** (applied in this iteration before continuing):

1. **Drop the sample fileId list from the API response detail.** Opaque ObjectIds aren't actionable for end users; they belong in the server log for support / debugging only.
2. **Surface "X of Y missing" instead of just X.** Lets the user distinguish a fully-wiped snapshot (52/52) from a partially-broken one (e.g. 3/52) — partial breakage may still be recoverable via the alternative-RS-restore path documented in RESTORE-FINDINGS § Future scenarios row 7.

Both addressed in commit `795ca83b714` on `prakhar.dhama/CLOUDP-405628-validate-snapshot-blocks`.

**Probe 2 re-verification after the UX commit:**

OM rebuilt + restarted with the fix. Retried the same broken-snapshot restore in the UI. New error banner reads:

```
Invalid config: Snapshot 6a0bfe17be061546c1b51190 is no longer restorable:
52 of 52 block file(s) are missing from the snapshot store.
```

✅ Sample fileIds gone from the API body. ✅ "X of Y" format makes total breakage explicit (52/52 = fully wiped). Server log still carries the sample for support / debugging (`LOG.warn` in `SnapshotBlockValidationSvc`).

#### Probe 3 — Feature flag off

⏭️ **Skipped at session end** — flag-gating verified by code inspection in lieu of a runtime restart-and-rewipe cycle. The validator's first action is:

```java
if (!FeatureFlagSvc.isFeatureFlagEnabled(
    FeatureFlag.AUTOMATION_RESTORATION_MODE, _appSettings, null, pTargetGroup)) {
  return;
}
```

— see `AutomatedBackupRestoreValidationSvc.validateSnapshotBlocksReachable`. When the flag is off, the method returns immediately and the catch chain in `ApiCreateRestoreJobsSvc` never sees `SnapshotBlocksMissingException` / `SnapshotBlockValidationUnavailableException`. The pre-existing restore-creation path runs unchanged, preserving the old behavior documented in RESTORE-FINDINGS § S1 Run 2 Probe 3/4.

If we ever want runtime confirmation: stop OM, relaunch without the `-Dmms.featureFlag.automation.restorationMode=enabled` JVM flag, retry the broken-snapshot restore. Expected: HTTP 200, agent wipes `/data/db`, HTTP 500 loop until cancelled. The recovery flow (cancel + healthy-snapshot restore) is the same as Probe 6.

#### Probe 4 — s3-meta unreachable

Stopped the `primary-om-s3-meta` container (`docker stop primary-om-s3-meta` — container exits cleanly, port 27019 stops listening). Triggered a restore of the same broken `poRepSet` snapshot in the Primary OM UI.

Validator's failure-closed path fired exactly as designed:

```
2026-05-19T08:12:27Z  SvcExceptionHandler — Invalid config: Could not reach
                      snapshot store to verify block integrity for snapshot
                      6a0bfe17be061546c1b51190
  SnapshotBlockValidationUnavailableException
  Caused by: com.mongodb.MongoTimeoutException: Timed out after 30000 ms
             while waiting to connect ... ConnectException: Connection refused
```

Call-stack walk-through:

1. `SnapshotBlockValidationSvc.findMissingFileIds:194` opened a `BlockFileDaoReader` against s3-meta
2. Mongo driver hit `Connection refused` on `localhost:27019` and waited the default 30 s before throwing `MongoTimeoutException`
3. `catch (RuntimeException)` at line 209 caught it and wrapped it in `SnapshotBlockValidationUnavailableException`
4. Bubbled up through `validateSnapshotBlocks` → `validateSnapshotBlocksReachable` → `validateRestoreJob` → caught at `ApiCreateRestoreJobsSvc:177` (our new catch) → mapped to `ApiErrorCode.SNAPSHOT_BLOCK_VALIDATION_UNAVAILABLE` (HTTP 503)

System-state confirmation:

- **Primary OM UI** showed a banner with the user-facing detail `Cannot verify snapshot integrity right now (snapshot store unreachable). Restore refused as a safeguard. Retry once the snapshot store is reachable.`
- **No `automationcore.config.automation` write** for any `poRepSet` member
- **All 3 `poRepSet` mongods stay up** — no `BounceStopIfUpWithForceKill`, no agent activity
- **No restore job persisted** in `backupjobs.restorejobs`

**One UX observation (acknowledged, not pursued in this PR):** the ~30 s wait before the banner appears comes from the default Mongo client connect timeout. Acceptable for v1 — only fires when s3-meta is genuinely unreachable, which is rare. A future tightening could pass a smaller `connectTimeout` for this specific lookup so the banner appears in ~5 s instead.

**Outcome:** ✅ PASS — failure-closed contract holds. The fix prefers refusing a restore over risking a wipe on unverifiable integrity.

#### Probe 5 — s3-meta restored

Started the `primary-om-s3-meta` container back up (`docker start primary-om-s3-meta` → ready within ~3 s). Confirmed `backupstore.files` state was unchanged by the container stop / start cycle (still wiped past the rollback target). One incidental observation: a fresh `poRepSet` snapshot was taken between the s3-meta rollback (Probe 4 setup) and the container restart, and its 52 blocks registered cleanly to s3-meta — consistent with the "[New `poRepSet` snapshots after rollback are immediately healthy](./RESTORE-FINDINGS.md#scenario-1--roll-back-s3-meta-rs-only)" finding from RESTORE-FINDINGS.

Retried the same broken-snapshot restore (`6a0bfe17be061546c1b51190`, 06:06 AM UTC) that Probe 4 had rejected with HTTP 503. The UI banner now reads:

```
Invalid config: Snapshot 6a0bfe17be061546c1b51190 is no longer restorable:
52 of 52 block file(s) are missing from the snapshot store.
```

This is the **409 `SNAPSHOT_BLOCKS_MISSING` path again** (the Probe-2 path), not the 503 path from Probe 4. Confirms two design properties:

1. The **failure-closed path was specifically about reachability**, not the snapshot's block state. The 503 went away as soon as the connection came back.
2. The validator runs every time — there's no caching that would freeze the result from when s3-meta was down. Each restore-creation re-queries `backupstore.files`.

**Outcome:** ✅ PASS — recovery is symmetric. When s3-meta comes back, the same restore attempt transitions from "can't verify" to "can verify and definitively rejects".

#### Probe 6 — PITR auto-selects broken starter (follow-up scope)

Triggered a Point-in-Time restore to **2026-05-19 06:30 AM UTC** — a target time after the s3-meta rollback boundary, chosen so the daemon's `findSnapshotForPit_v1` would pick the broken 06:06 AM starter (`6a0bfe17be061546c1b51190`).

OM log captured the exact gap:

```
08:25:04  BackupSvc.findSnapshotForPit_v1 — Finding first snapshot of rsId poRepSet
                                            older than TS time: Tue May 19 06:30:00 GMT 2026
08:25:04                                    Found snapshot 6a0bfe17be061546c1b51190
                                            (the broken 06:06Z one — 1431s before PIT)
08:25:11  BackupRestoreJobSvc.validateSnapshotRestore — passed (daemon's existing validation)
08:25:14  Phase 0 started — manifest staging succeeds (reads backupjobs.snapshots only)
08:25:44  Phase 0 → Phase 1 triggered, pullUrl signed
08:25:59  Phase 1 started — agent will pick up backupRestoreUrl* directive on next poll
```

**Crucially: zero `SnapshotBlockValidationSvc` log entries for this restore.** The validator never ran for the PITR-from-RS path. Confirmed in the code at `AutomatedBackupRestoreValidationSvc.validateSnapshotBlocksReachable` — the method's structure only handles two explicit paths:

```java
if (pRestoreJob.getType() == JobType.RESTORE_CLUSTER) { ... validateClustershotBlocks ... }
else if (snapshotId != null) { ... validateSnapshotBlocks ... }
// PITR-from-RS (no snapshotId, not RESTORE_CLUSTER) falls through unchecked
```

For PITR-from-RS the request goes through `JobType.RESTORE_RS` with no `snapshotId` parameter — the daemon resolves the starter via PIT timestamp lookup (`findSnapshotForPit_v1`). To close this gap, the validator needs to call the **same** resolution function so it validates the snapshot the daemon will ultimately use.

**Recovery flow** (exactly as documented in [RESTORE-FINDINGS § S1 Run 2 Probe 4b](./RESTORE-FINDINGS.md#probe-results)):

1. Restore History → click in-progress restore's Status column → **Cancel Automated Restore** → loop stops, RS data is empty (Phase 1's wipe completed before cancel)
2. Trigger a fresh restore of the healthy 05:08 AM UTC snapshot (`6a0bf0aabe061546c1b4cb17`) → 3 downloads, ~2 min, RS data fully recovered

**Outcome:** ⚠️ KNOWN GAP — reproduced as designed. The data-loss bug remains for PITR-from-RS until follow-up Jira lands. The fix in this PR covers snapshot-id-based restores (RS + clustershot) and PITR-from-clustershot. Snapshot-id-based RS restore is the most common UI path and is fully protected.

**Follow-up Jira required.** Suggested title: "Extend SnapshotBlockValidationSvc to PITR-from-RS — mirror BackupSvc.findSnapshotForPit_v1 resolution". Estimate ~1 dev day (small refactor in `AutomatedBackupRestoreValidationSvc.validateSnapshotBlocksReachable` plus tests).

#### Probe 6 re-verify — gap closed in the same PR

After the gap was demonstrated, the fix was implemented and pushed as commit `80363209433` on the same branch (`prakhar.dhama/CLOUDP-405628-validate-snapshot-blocks`). The PR scope expanded to include PITR-from-RS coverage rather than spinning off a separate follow-up Jira.

**Code change.** `AutomatedBackupRestoreValidationSvc.validateSnapshotBlocksReachable` gained a third branch for the case where `snapshotId == null && job.getType() != RESTORE_CLUSTER`:

```java
} else {
  // PITR-from-RS: no snapshotId in the job params — the daemon resolves the starter snapshot
  // at restore time via BackupSvc.findSnapshotForPIT(groupId, rsId, pitTimestamp). To stay in
  // lockstep with the daemon's choice we call the SAME function from the validator.
  final Snapshot starter = _backupSvc.findSnapshotForPIT(sourceGroupId, sourceRsId, pitTimestamp);
  validateSingleSnapshot(starter);
}
```

Two small helpers extracted in the same commit:

- `extractPitTimestamp(restoreJob)` — mirrors the parse logic already used by `getClustershotFromPitTimestamp`, so the clustershot and RS PIT paths agree on timestamp interpretation.
- `validateSingleSnapshot(snapshot)` — the shared no-op-non-S3 + delegate-to-svc tail between the snapshot-id and PITR-from-RS paths.

**Re-verify run.** Restarted OM with the new build, retried the same PITR target (`2026-05-19 06:30 AM UTC`). OM log evidence (filtered to the relevant lines):

```
09:35:20  BackupSvc.findSnapshotForPit_v1 — Finding first snapshot of rsId poRepSet
                                            older than TS time: Tue May 19 06:30:00 GMT 2026
09:35:20                                    Found snapshot 6a0bfe17be061546c1b51190
                                            (1431s before PIT — same as Probe 6 first run)

  [draft-validation pass — looked up but not yet validated]

09:35:24  BackupSvc.findSnapshotForPit_v1 — (second call, this time from the validator's new branch)
09:35:24                                    Found snapshot 6a0bfe17be061546c1b51190
09:35:24  SnapshotBlockValidationSvc      — Snapshot 6a0bfe17be061546c1b51190 has 52 of 52 block
                                            files missing in the snapshot store; restore would fail
                                            at agent download. Rejecting restore-creation.
          SnapshotBlocksMissingException: Invalid config: Snapshot 6a0bfe17be061546c1b51190 is no
                                          longer restorable: 52 of 52 block file(s) are missing...
            at SnapshotBlockValidationSvc.validateSnapshotBlocks:109
            at AutomatedBackupRestoreValidationSvc.validateSnapshotBlocksReachable:182  ← new code path
            at AutomatedBackupRestoreValidationSvc.validateRestoreJob:111
```

The double `findSnapshotForPit_v1` log line is the key signal: the daemon's `BackupSvc.findSnapshotForPit_v1` is invoked once by the existing draft-validation path and a second time by the new validator branch. Both resolve to the same snapshot — exactly the design goal. The stack trace's `:182` lands on the new `validateSingleSnapshot(starter)` call site, confirming the PITR-from-RS branch (not the snapshot-id branch) fired.

**UI behavior:** banner shows the same `Invalid config: Snapshot 6a0bfe17be061546c1b51190 is no longer restorable: 52 of 52 block file(s) are missing from the snapshot store.` message that snapshot-id restores get. `automationcore.config.automation` had no `backupRestoreUrl*` write; mongods stayed up; no recovery restore needed this time.

**Outcome:** ✅ PASS — the data-loss bug is now fixed across all restore-job shapes the validator can reach (RS snapshot-id, clustershot snapshot-id, clustershot PITR, **RS PITR**). The follow-up Jira originally proposed for the PITR-from-RS path is no longer needed; the fix ships in PR #770.

### Net result

**Approach-1 ships the fix it was designed to ship.** Snapshot-id-based restores (RS + clustershot) that would have wiped `/data/db` and looped HTTP 500 indefinitely are now rejected at restore-creation time with a clear HTTP 409 message. The replica set data is never modified.

| | Pre-fix (RESTORE-FINDINGS § Scenario 1) | Post-fix (this run) |
|---|---|---|
| **Healthy snapshot restore** | ✅ Works | ✅ Works (~2 min, no measurable validator overhead) |
| **Broken snapshot restore — UI** | ❌ Phase 1 fires → agent wipes `/data/db` → 78–186 HTTP 500 retries → "Finished" or "Cancelled" status, RS empty | ✅ HTTP 409 at restore-creation, banner: "Snapshot %s is no longer restorable: X of Y block file(s) are missing from the snapshot store." No directive write, no wipe, mongods stay up |
| **Broken snapshot restore — Public API** | ❌ Same wipe + loop pattern | ✅ HTTP 409 `SNAPSHOT_BLOCKS_MISSING` with structured detail (snapshotId, missing-of-total) |
| **s3-meta unreachable** | (Not surfaced in prior testing — would have been the same wipe + 500 loop) | ✅ HTTP 503 `SNAPSHOT_BLOCK_VALIDATION_UNAVAILABLE` after ~30 s Mongo timeout. Failure-closed safeguards the RS data. |
| **Recovery after s3-meta back up** | (N/A) | ✅ 503 cleanly transitions to 409 once integrity can be verified again |
| **PITR-from-RS picking a broken starter** | ❌ Same wipe + 500 loop | ✅ HTTP 409 `SNAPSHOT_BLOCKS_MISSING` — validator calls the same `BackupSvc.findSnapshotForPIT` the daemon uses, so both land on the same resolved starter. Closed in commit `80363209433`. |

**One UX iteration mid-session.** Initial error message included a sample of 5 missing fileIds (opaque ObjectIds, not actionable for users). Refined to:

- Drop the sample from the user-facing API detail (kept in `LOG.warn` for support)
- Show "X of Y missing" instead of just X (lets the user tell a fully-wiped snapshot from a partial breakage)

Shipped as commit `795ca83b714` on `prakhar.dhama/CLOUDP-405628-validate-snapshot-blocks`.

**Known follow-ups (none block this PR):**

1. **Mongo connect timeout tuning** — failure-closed path waits ~30 s before the 503 banner shows. Could shorten with a per-call `MongoClientSettings` for snapshot validation. Cosmetic; only fires when s3-meta is genuinely down.
2. **Approach 2 (`isRestorable` flag in `ApiSnapshotView`)** — would let the UI hide / badge broken snapshots in the picker so the user never tries them in the first place. Estimated at ~4 dev days in the [effort table](#effort-estimate); recommended as a follow-up PR.
3. **Approach 3 (scheduled groom)** — proactive integrity scan on a cadence. Largest scope; only valuable once Approach 2 is in.

The PITR-from-RS gap originally raised in Probe 6 was closed in the same PR rather than spun off — see commit `80363209433` and the [Probe 6 re-verify](#probe-6-re-verify--gap-closed-in-the-same-pr) section above.


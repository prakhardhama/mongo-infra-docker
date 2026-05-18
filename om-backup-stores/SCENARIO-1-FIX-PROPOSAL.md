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

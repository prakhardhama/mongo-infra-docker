# Deployment Reconciliation PoC — Findings

## BUG: Reconciliation trigger never fires (FIXED)

**Found:** 2026-04-13 during PoC Phase 3  
**Severity:** Critical — reconciliation is completely broken without this fix

**Symptom:** Restoration mode enters correctly (`restorationMode=true`, HTTP 304 returned to agents), but no reconciliation jobs are ever created in the `automation.job.status` queue. The config stays at the stale snapshot version indefinitely.

**How we found it:**
1. After PITR restore, agent polled with `cv=15`, OM detected `15 > 9` and set `restorationMode=true`
2. OM logs confirmed: `"Restoration mode enabled for group ... agentVersion: 15, dbVersion: 9"` (GroupDao)
3. OM logs confirmed: `"Version mismatch detected ... Entering restoration mode."` (AutomationConfigAPIResource)
4. But OM logs had **zero** entries from `ReconciliationTriggerSvc`, `ReconciliationOrchestrator`, or `RestorationModeSvc`
5. Job queue had no `CONFIG_METADATA_COLLECTION` or `CONFIG_UPLOAD` jobs

**Root cause:**

`AutomationConfigAPIResource.checkAndSetRestorationMode()` (line ~377) calls `_groupDao.trySetRestorationModeWithMetadata()` **directly**, bypassing `RestorationModeSvc.enterRestorationMode()`.

The reconciliation trigger (`ReconciliationTriggerSvc.triggerReconciliation()`) is wired into `RestorationModeSvc` (line 81), **not** the DAO. So the flag gets set in the DB correctly, but the reconciliation workflow is never invoked.

```
Call chain (BROKEN):
  AutomationConfigAPIResource.checkAndSetRestorationMode()
    → _groupDao.trySetRestorationModeWithMetadata()        ← sets flag in DB
    ✗ ReconciliationTriggerSvc.triggerReconciliation()      ← NEVER CALLED

Call chain (INTENDED):
  AutomationConfigAPIResource.checkAndSetRestorationMode()
    → _restorationModeSvc.enterRestorationMode()
        → _groupDao.trySetRestorationModeWithMetadata()    ← sets flag in DB
        → _reconciliationTriggerSvcProvider.get()
              .triggerReconciliation()                      ← dispatches background job
```

**Fix applied:**

File: `server/src/main/com/xgen/svc/atm/res/api/AutomationConfigAPIResource.java`

1. Added `RestorationModeSvc` import and field
2. Injected `RestorationModeSvc` via constructor
3. Changed `checkAndSetRestorationMode()` to call the service instead of the DAO

```java
// BEFORE (broken) — calls DAO directly, reconciliation never triggers
final boolean enteredRestorationMode =
    _groupDao.trySetRestorationModeWithMetadata(
        pGroup.getId(), RestorationModeReason.PITR_RESTORE, metadata);

// AFTER (fixed) — calls service which sets flag AND triggers reconciliation
_restorationModeSvc.enterRestorationMode(
    pGroup.getId(), RestorationModeReason.PITR_RESTORE, metadata);
```

---

## DESIGN GAP: No reconciliation re-trigger on OM restart

**Found:** 2026-04-13 during PoC Phase 3  
**Severity:** Medium — affects recovery after OM crash during reconciliation

**Symptom:** If Primary OM crashes or is restarted while `restorationMode=true` (i.e., during an ongoing reconciliation), the reconciliation is never re-triggered after restart.

**Root cause:** The reconciliation trigger only fires on the `false → true` transition inside `RestorationModeSvc.enterRestorationMode()`. On restart:
1. Agent polls with `cv=15`
2. OM reads group from DB, sees `restorationMode=true` already
3. Code at line 200-203 checks `if (!restorationModeActive && versionMismatch)` — this is `false` because `restorationModeActive` is already `true`
4. `checkAndSetRestorationMode()` is never called
5. OM returns 304 immediately — reconciliation is never re-triggered

**Workaround:** Manually reset `restorationMode=false` in AppDB while OM is running. The next agent poll will re-detect the mismatch and trigger reconciliation:
```javascript
db.getSiblingDB('mmsdbconfig').getCollection('config.customers').updateOne(
    {_id: ObjectId('<groupId>')},
    {$set: {restorationMode: false, restorationModeSetAt: null,
            restorationModeReason: null, restorationModeMetadata: null}}
)
```

**Recommended fix (follow-up):** Add a startup check in OM that scans for groups with `restorationMode=true` and re-triggers reconciliation for each.

---

---

## BUG: Config validation rejects agent's unwrapped config format (FIXED)

**Found:** 2026-04-13 during PoC Phase 3 (after fixing the trigger bug above)  
**Severity:** Critical — reconciliation completes metadata collection and config upload, but fails at the final validation step

**Symptom:** After the trigger fix, the full reconciliation flow executes:
1. CONFIG_METADATA_COLLECTION job succeeds (version=15, host=M-FNVDKKWYJR)
2. Canonical config selected (host=M-FNVDKKWYJR, version=15)
3. CONFIG_UPLOAD job succeeds (21268 bytes uploaded)
4. **Validation fails:** `"Uploaded config has no 'cluster' field"`

**Root cause:**

The agent's local config backup (`mms-cluster-config-backup.json`) uses an **unwrapped format** where `processes`, `replicaSets`, `sharding`, etc. are top-level fields. The AppDB stores these under a `cluster` wrapper object.

`ReconciliationConfigSvc.validateAndPersist()` (line ~70) only checks for `parsed.get("cluster")` and throws if null — it doesn't handle the unwrapped agent format.

```
AppDB format:     { version: 15, cluster: { processes: [...], replicaSets: [...] } }
Agent format:     { version: 15, processes: [...], replicaSets: [...] }
                                 ↑ no 'cluster' wrapper
```

**Fix applied:**

File: `server/src/main/com/xgen/svc/atm/svc/ReconciliationConfigSvc.java`

Added fallback logic: if `cluster` field is missing but `processes` field exists at the top level, treat the entire parsed document as the cluster content.

```java
// BEFORE — only accepts wrapped format
Object clusterObj = parsed.get("cluster");
if (clusterObj == null) {
    throw new ConfigValidationException("Uploaded config has no 'cluster' field");
}

// AFTER — handles both wrapped and unwrapped formats
Object clusterObj = parsed.get("cluster");
if (clusterObj == null && parsed.get("processes") != null) {
    LOG.info("Uploaded config uses unwrapped agent format, adapting");
    clusterObj = parsed;  // treat entire doc as the cluster
}
```

---

## BUG: Enum mismatches in agent config deserialization (FIXED)

**Found:** 2026-04-13 during PoC Phase 3 (after fixing the two bugs above)  
**Severity:** Critical — config upload succeeds but deserialization fails

**Symptom 1 — ProcessType:** `Cannot deserialize "mongod": not one of [MONGOD, MONGOS]`  
Agent stores `processType: "mongod"` (lowercase), OM enum constant is `MONGOD` (uppercase).

**Symptom 2 — Platforms:** `Cannot deserialize "osx": not one of [Windows, Linux, Mac OS X]`  
Agent stores `"osx"` (enum constant name), but Jackson with `READ_ENUMS_USING_TO_STRING` matched against `toString()` which returns `"Mac OS X"` (the fullName field).

**Root cause:** The `ObjectMapper` in `ReconciliationConfigSvc` had no case-insensitive enum handling. An initial fix using `READ_ENUMS_USING_TO_STRING` fixed `ProcessType` but broke `Platforms` because `Platforms.toString()` returns the full name (`"Mac OS X"`) not the constant name (`osx`).

**Fix applied:**

File: `server/src/main/com/xgen/svc/atm/svc/ReconciliationConfigSvc.java`

- `ACCEPT_CASE_INSENSITIVE_ENUMS` — matches by enum constant name, case-insensitive (`"mongod"` → `MONGOD`, `"osx"` → `osx`)
- `READ_UNKNOWN_ENUM_VALUES_AS_NULL` — gracefully handles any remaining mismatches instead of throwing

```java
private static final ObjectMapper MAPPER =
    new ObjectMapper()
        .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)
        .configure(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES, false)
        .configure(DeserializationFeature.READ_UNKNOWN_ENUM_VALUES_AS_NULL, true)
        .enable(MapperFeature.ACCEPT_CASE_INSENSITIVE_ENUMS);
```

**Key insight:** Do NOT use `READ_ENUMS_USING_TO_STRING` when enums override `toString()` to return different values than the constant name. Use `ACCEPT_CASE_INSENSITIVE_ENUMS` for case-only differences.

---

## BUG: Reconciliation version cycling — republish increments instead of preserving agent version (FIXED)

**Found:** 2026-04-13 during PoC Phase 4  
**Severity:** Medium — reconciliation succeeds but takes multiple cycles to stabilize

**Symptom:** After reconciliation persists the config and exits restoration mode, the agent's next poll re-triggers reconciliation because the new DB version (e.g. 10) is less than the agent's version (15). This repeats until the DB version catches up to the agent's version (one cycle per version increment: 10→11→12→...→15).

**Root cause:** `AutomationConfigDao.save()` always increments the version by 1:
```java
pPublishable.setVersion(pPublishable.getVersion() + 1L);
```

So when the restored config is at version 9 and reconciliation republishes it, the new version becomes 10 — not 15 (the agent's version). The agent sees `cv=15 > db=10` and triggers another cycle.

**Fix applied:**

After `rePublishTransaction` succeeds, if the new version is still less than the agent's uploaded version, bump the version directly to match. This is done via a new `setPublishedVersion()` method that atomically updates the version field in the DB.

Files changed:
- `server/src/main/com/xgen/svc/atm/svc/ReconciliationConfigSvc.java` — after republish, call `setPublishedVersion` if needed
- `server/src/main/com/xgen/cloud/atm/publish/_public/svc/AutomationConfigPublishingSvc.java` — new `setPublishedVersion` delegate
- `server/src/main/com/xgen/cloud/atm/core/_private/dao/AutomationConfigDao.java` — new `setPublishedVersion` atomic update

```java
// In ReconciliationConfigSvc.validateAndPersist():
final long newVersion = _automationConfigSvc.rePublishTransaction(pGroupId, published);

// Bump version to agent's version to prevent re-trigger cycle
if (newVersion < uploadedVersion) {
    _automationConfigSvc.setPublishedVersion(pGroupId, uploadedVersion);
}
```

---

## Automation config schema: `cluster.processes` not `processes`

**Found:** 2026-04-12 during PoC Phase 1

The automation config document in `automationcore.config.automation` stores processes under `doc.cluster.processes` and replica sets under `doc.cluster.replicaSets`, **not** as top-level fields. This is the On-Prem OM schema — differs from what the TD code snippets assumed.

Scripts querying the config must use:
```javascript
var cluster = doc.cluster || {};
var procs = cluster.processes || doc.processes || [];
var rsSets = cluster.replicaSets || doc.replicaSets || [];
```

---

## Container IP drift breaks Meta OM agent

**Found:** 2026-04-12 during environment setup

Docker assigns IPs dynamically on each container start. If `mongodb-ops-manager` gets a different IP after restart (e.g., `172.18.0.2` instead of `172.18.0.4`), the Meta OM automation agent's cached `alias` field becomes stale. The agent tries to connect to the old IP and fails with `connection refused`.

**Fix:** Always create the container with a static IP matching what Meta OM expects:
```bash
docker run ... --ip 172.18.0.4 --network ops-manager_main ...
```

Start `mongodb-ops-manager` **before** other containers on the same network to avoid IP collisions, or use `--ip` to guarantee the assignment.

---

## RS member host must survive container IP changes

**Found:** 2026-04-12 during environment setup

When the appDB container's IP changes, the RS config in `/data/db` still references the old IP. Mongod can't self-identify as a member, fails to elect PRIMARY, and OM gets `Replica set name 'null'` errors.

**Fix options:**
1. Use hostname-based RS member (`9fb2861bd327:27017`) — works when `--hostname` is fixed and OM uses `directConnection=true`
2. Use static IP with `--ip` flag — preferred for this PoC since it avoids all resolution issues

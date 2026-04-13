# Deployment Reconciliation PoC Plan

**Status:** IN PROGRESS  
**Depends on:** [DR PoC](../om-disaster-recovery/DR-POC-PLAN.md) (completed March 6, 2026)  
**Related:** [SPIKE + TD] OM Backup with PITR and Deployment Reconciliation  
**Jira Epic:** [CLOUDP-388020](https://jira.mongodb.org/browse/CLOUDP-388020)

---

## Objective

Demonstrate that after a catastrophic loss and PITR restore of Primary OM's appDB, the **deployment reconciliation engine** automatically converges the automation config to match the actual state of managed deployments — even when the snapshot is stale.

**Core scenario:**  
`poRepSet` has 3 nodes → snapshot taken → scaled to 5 nodes → disaster destroys appDB → restore from 3-node snapshot → **reconciliation detects mismatch and converges to 5 nodes**.

## Background

The [DR PoC](../om-disaster-recovery/DR-POC-PLAN.md) proved we can restore Primary OM's appDB from Meta OM snapshots. However, a restored snapshot may be stale — deployments may have been modified between the last snapshot and the disaster. Without reconciliation, Primary OM would push the stale (older) config to agents, **reverting live deployments** to the snapshot state.

Phase 1 of the OM Backup project (Tracks 1-3, merged) introduces:

1. **Restoration Mode** — freezes agent config delivery (HTTP 304) and blocks UI/API writes when a version mismatch is detected.
2. **Reconciliation Engine** — collects config metadata from agents, selects the canonical (highest-version) config, uploads it to AppDB, and exits restoration mode.

This PoC validates that end-to-end flow in a real environment.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Meta Ops Manager                         │
│                    (Docker — Port 8080)                      │
│                                                              │
│  - Manages Primary OM's appDB replica set                   │
│  - Takes continuous backups + PITR snapshots                 │
│  - Used to restore appDB after disaster                     │
└──────────────────────────┬──────────────────────────────────┘
                           │ Manages & Backs Up
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              Primary OM's appDB Replica Set                  │
│                  (Docker — Port 27018)                       │
│                                                              │
│  - Container: mongodb-ops-manager                           │
│  - Replica Set: appdb-rs                                    │
│  - Volume: primary-om-appdb                                 │
│  - Key collection: automationcore.config.automation          │
│     └─ version, processes[], replicaSets[]                  │
│  - Key collection: mmsdbconfig.config.customers              │
│     └─ restorationMode, restorationModeSetAt, ...           │
└──────────────────────────┬──────────────────────────────────┘
                           │ Used By
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                  Primary Ops Manager                         │
│                  (Bazel — Port 8081)                         │
│                                                              │
│  conf: conf-hosted.properties                               │
│  Feature flag: mms.featureFlag.automation.restorationMode   │
│                                                              │
│  Key APIs:                                                   │
│   GET /automation/api/conf/v1/{groupId}?cv={version}        │
│     → returns 304 when restorationMode=true                 │
│   Reconciliation engine (background):                        │
│     → CollectConfigMetadataAgentJob                          │
│     → UploadAutomationConfigAgentJob                         │
│     → Persists canonical config → exits restoration mode    │
└──────────────────────────┬──────────────────────────────────┘
                           │ Manages
                           ▼
┌─────────────────────────────────────────────────────────────┐
│         Managed Deployment: poRepSet (target RS)            │
│                                                              │
│  - Automation agents on each host                            │
│  - Each agent stores config locally at:                      │
│    /var/lib/mongodb-mms-automation/mms-cluster-config-       │
│    backup.json                                               │
│  - Agent sends cv={version} in poll requests                │
│  - Agent flag: omBackupFeatureFlag=true                      │
└─────────────────────────────────────────────────────────────┘
```

## Reconciliation Flow (What We're Testing)

```
 PRE-DISASTER                    DISASTER              POST-RESTORE
─────────────────────────────────────────────────────────────────────

poRepSet: 3 nodes               appDB destroyed        appDB restored
  config version: V                                      from snapshot
      │                                                  config: V (3 nodes)
      │
      ▼
poRepSet scaled to 5 nodes                             Agents still have
  config version: V+N                                   config V+N (5 nodes)
  (snapshot is now stale)                                    │
                                                             ▼
                                                     Agent polls OM with
                                                       cv=V+N
                                                             │
                                                             ▼
                                               OM detects V+N > V (mismatch)
                                                             │
                                                             ▼
                                               ┌─────────────────────────┐
                                               │ ENTER RESTORATION MODE  │
                                               │                         │
                                               │ • restorationMode=true  │
                                               │ • 304 to all agents     │
                                               │ • UI/API writes blocked │
                                               └────────────┬────────────┘
                                                             │
                                                             ▼
                                               ┌─────────────────────────┐
                                               │ RECONCILIATION JOB 1    │
                                               │ Collect Config Metadata │
                                               │                         │
                                               │ For each host:          │
                                               │  → CONFIG_METADATA_     │
                                               │    COLLECTION job       │
                                               │  → Returns: version,    │
                                               │    timestamp, hostname  │
                                               │  → Select highest ver.  │
                                               └────────────┬────────────┘
                                                             │
                                                             ▼
                                               ┌─────────────────────────┐
                                               │ RECONCILIATION JOB 2    │
                                               │ Upload Canonical Config │
                                               │                         │
                                               │ → CONFIG_UPLOAD job to  │
                                               │   host with highest ver │
                                               │ → Agent sends full      │
                                               │   config to OM          │
                                               │ → OM validates & saves  │
                                               │   to AppDB              │
                                               └────────────┬────────────┘
                                                             │
                                                             ▼
                                               ┌─────────────────────────┐
                                               │ EXIT RESTORATION MODE   │
                                               │                         │
                                               │ • restorationMode=false │
                                               │ • Agents get V+N config │
                                               │ • UI/API writes resume  │
                                               │ • poRepSet shows 5 nodes│
                                               └─────────────────────────┘
```

## Prerequisites

### Infrastructure (same as DR PoC)
- [ ] Meta OM running in Docker (port 8080)
- [ ] Primary OM's appDB replica set running (port 27018, container: `mongodb-ops-manager`)
- [ ] Primary OM running locally via Bazel (port 8081)

### Feature Flags (NEW — required for reconciliation)

**1. Ops Manager — `mms.featureFlag.automation.restorationMode`**

Default in `conf-hosted.properties` is `disabled`. Must be `enabled` at OM startup.

```bash
# Option A: JVM flag override
cd /Users/prakhar.dhama/ops-manager
bazel run --server_env=hosted //server:mms -- \
  --jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled

# Option B: Environment variable
export MMSENV_MMS_FEATUREFLAG_AUTOMATION_RESTORATIONMODE=enabled
bazel run --server_env=hosted //server:mms
```

What it does:
- Enables version mismatch detection in `AutomationConfigAPIResource.java`
- When agent sends `cv=V+N` and AppDB has version `V`, sets `restorationMode=true` on the group
- Returns HTTP 304 to agent polls while restoration mode is active
- Triggers reconciliation jobs in the background

Flag definition: `server/src/main/com/xgen/cloud/common/featureFlag/_public/model/FeatureFlag.java` (line ~870)
```java
AUTOMATION_RESTORATION_MODE(
    opts().appSetting("mms.featureFlag.automation.restorationMode").scope(Scope.GROUP));
```

**2. Automation Agent — `omBackupFeatureFlag`**

Must be `true` on agents managing the target deployment (`poRepSet`).

**Local development setup (running agent from source):**

The agent is run locally via `go run` with a config file:

```bash
cd ~/mms-automation/go_planner/src/com.tengen/cm/main
go run cm.go --config=local.config
```

Add `omBackupFeatureFlag=true` to `local.config`:

```properties
# ~/mms-automation/go_planner/src/com.tengen/cm/main/local.config
mmsGroupId=69d63cee84a3663972169b36
mmsApiKey=69d63d5d84a3663972169ddd5fdf142892a3708d93b6b394abb78ba6
mmsBaseUrl=http://localhost:8081
logFile=/var/log/mongodb-mms-automation/primary-automation-agent.log
mmsConfigBackup=/var/lib/mongodb-mms-automation/mms-cluster-config-backup.json
logLevel=INFO
maxLogFiles=10
maxLogFileSize=268435456

# OM Backup — enable config version (cv) in poll requests
omBackupFeatureFlag=true
```

How it works: The agent's config file parser (`flags.go:ReadAutomationConfigFile`) reads
key=value pairs and maps them via `BoolFlagNamed`. The key `omBackupFeatureFlag` sets
`global.OmBackupFeatureFlag = true`, which makes the agent include `cv={version}` in
its poll URL (`urlretriever.go:RetrieveWithConfigVersion`).

**Docker container agents (e.g. appDB agent installed by `meta-om-primary-appdb-agent-installation.sh`):**

```bash
# Add to the agent config inside the container
docker exec mongodb-ops-manager bash -c \
  'echo "omBackupFeatureFlag=true" >> /etc/mongodb-mms/automation-agent.config'
# Restart the agent for the change to take effect
```

What it does:
- Enables the agent to send config version (`cv`) query parameter when polling OM
- Without this flag, the agent does NOT send `cv`, so OM cannot detect the version mismatch
- Defined in `go_planner/src/com.tengen/cm/global/global.go` (line ~145)
- Registered in `go_planner/src/com.tengen/cm/global/flags/flags.go` (line ~348)

### Deployment
- [ ] A replica set `poRepSet` exists in Primary OM with an initial node count (e.g. 3 nodes)
- [ ] Agents for `poRepSet` have `omBackupFeatureFlag=true`
- [ ] A Meta OM snapshot exists that captures the current config (3 nodes)

**Script:** `./om-disaster-reconciliation/1-verify-setup.sh`

## PoC Phases

### Phase 1: Verify Setup & Baseline

**Status:** IN PROGRESS  
**Script:** `./om-disaster-reconciliation/1-verify-setup.sh`

**What it does:**
1. Verifies infrastructure (Meta OM, Primary OM, appDB)
2. Queries `automationcore.config.automation` for `poRepSet` topology:
   - Config version, process count, member count, hostnames
3. Checks feature flag schema (`restorationMode` field on group document)
4. Verifies backup snapshots exist in Meta OM
5. Saves baseline to `/tmp/reconciliation-poc/baseline-latest.json`

**Expected output:**
- All infrastructure checks pass
- `poRepSet`: N processes, N members, config version V
- `restorationMode` field present in group document
- At least 1 Meta OM snapshot for `appdb-rs`

**Environment variable overrides:**
```bash
# Track a different replica set
TARGET_RS=myOtherRS ./1-verify-setup.sh

# Enable Primary OM API checks (for agent status)
PRIMARY_OM_PUBLIC_KEY=xxx PRIMARY_OM_PRIVATE_KEY=yyy ./1-verify-setup.sh
```

### Phase 2: Simulate Disaster

**Status:** NOT STARTED  
**Script:** `./om-disaster-reconciliation/2-simulate-disaster.sh`

**Precondition:**  
After Phase 1 passes, scale `poRepSet` from 3 → 5 nodes via Primary OM UI, wait for agents to converge, then run this script. The Meta OM snapshot still has the 3-node config.

**What it does:**
1. Documents pre-disaster state:
   - Config version, `poRepSet` node count (should be 5), agent config versions
   - Saves to `/tmp/reconciliation-poc/pre-disaster-*.json`
2. Stops Primary OM (bazel process)
3. Destroys appDB container and volume (catastrophic failure)
4. Verifies complete data loss

**Key difference from DR PoC disaster script:**  
We specifically record the **post-scale** topology (5 nodes) before destroying, so Phase 4 can compare against it.

### Phase 3: Restore & Observe Reconciliation

**Status:** NOT STARTED  
**Script:** `./om-disaster-reconciliation/3-restore-and-reconcile.sh`

**What it does:**
1. Prepares infrastructure (same as DR PoC `3-automated-restore-prepare.sh`):
   - Creates container with original hostname
   - Installs automation agent as mongod user
2. Prompts to trigger PITR restore from Meta OM UI
3. Waits for restore to complete
4. Starts Primary OM **with restoration mode flag enabled**:
   ```bash
   bazel run --server_env=hosted //server:mms -- \
     --jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled
   ```
5. Monitors for reconciliation:
   - Watches `restorationMode` flag on group document (should flip to `true` then back to `false`)
   - Watches config version in `automationcore.config.automation`
   - Tails Primary OM logs for reconciliation activity:
     - `"PITR detected: Agent config version"` — mismatch detection
     - `"Set restoration mode to true"` — entering restoration mode
     - `"CONFIG_METADATA_COLLECTION"` — job 1 running
     - `"CONFIG_UPLOAD"` — job 2 running
     - `"Set restoration mode to false"` — reconciliation complete
   - Tails agent logs for 304 responses and job execution

### Phase 4: Verify Reconciliation

**Status:** NOT STARTED  
**Script:** `./om-disaster-reconciliation/4-verify-reconciliation.sh`

**What it does:**
1. Reads baseline from Phase 1 and pre-disaster state from Phase 2
2. Queries current `automationcore.config.automation`:
   - Config version (should match pre-disaster, not snapshot)
   - `poRepSet` process count (should be 5, not 3)
   - `poRepSet` member count (should be 5, not 3)
   - Hostnames match pre-disaster
3. Checks `restorationMode` is `false` (reconciliation completed)
4. Checks agents are healthy and converged
5. Compares:

   | Field | Snapshot (Phase 1) | Pre-Disaster (Phase 2) | Post-Reconciliation |
   |---|---|---|---|
   | Config version | V | V+N | **V+N** (reconciled) |
   | poRepSet nodes | 3 | 5 | **5** (reconciled) |
   | restorationMode | false | false | **false** (exited) |

6. Optionally verifies actual MongoDB RS membership matches config

**Success criteria:**
- Config version matches pre-disaster (not snapshot)
- `poRepSet` shows 5 nodes (not 3)
- `restorationMode` is `false`
- No UID mismatch or agent errors

## Implementation Details (from merged PRs)

### Track 1: Agent-Side Changes (mms-automation)
**PR:** [CLOUDP-388021](https://jira.mongodb.org/browse/CLOUDP-388021)

- **Config version in poll API** (`urlretriever.go`): Agent sends `cv={version}` query parameter when `omBackupFeatureFlag=true`
- **CONFIG_METADATA_COLLECTION job** (`configmetadatacollectionjob.go`): Returns config version, timestamp, hostname from local config backup
- **CONFIG_UPLOAD job** (`configuploadjob.go`): Uploads full automation config (with sensitive fields redacted) to OM

### Track 2: OM Core Infrastructure (ops-manager)
**PR:** [CLOUDP-388025](https://jira.mongodb.org/browse/CLOUDP-388025)

- **AppDB schema** (`Group.java`): Added `restorationMode`, `restorationModeSetAt`, `restorationModeReason`, `restorationModeMetadata` fields
- **Group DAO** (`GroupDao.java`): `setRestorationMode()`, `isRestorationModeEnabled()`, `clearRestorationMode()`
- **Automation Config API** (`AutomationConfigAPIResource.java`): Accepts `cv` param, detects version mismatch, enters restoration mode, returns 304
- **RestorationModeSvc** (`RestorationModeSvc.java`): Lifecycle management, triggers reconciliation on entry
- **Backup gating** (`RestorationModeSvc.java`): Blocks backup operations during restoration mode

### Track 3: Reconciliation Engine (ops-manager)
**PR:** [CLOUDP-388026](https://jira.mongodb.org/browse/CLOUDP-388026)

- **Agent jobs** (`CollectConfigMetadataAgentJob.java`, `UploadAutomationConfigAgentJob.java`)
- **Orchestrator** (`ReconciliationOrchestrator.java`): Two-phase workflow — collect metadata → select canonical → upload → persist → exit restoration mode
- **Trigger** (`ReconciliationTriggerSvc.java`): Fire-and-forget background job when restoration mode is set
- **Config selection** (`ReconciliationConfigSvc.java`): Highest version wins; tie-break by timestamp, then hostname
- **Result store** (`ReconciliationResultStore.java`): Persists reconciliation outcomes

### Track 4: UI/API Guardrails (NOT YET MERGED)
**Jira:** [CLOUDP-388027](https://jira.mongodb.org/browse/CLOUDP-388027)

- Block public API writes during restoration mode (HTTP 409)
- Disable UI deployment modification controls
- Restoration mode status API

## Key AppDB Collections

| Collection | Database | Purpose |
|---|---|---|
| `config.automation` | `automationcore` | Automation config (version, processes, replicaSets) |
| `config.customers` | `mmsdbconfig` | Group/project documents (restorationMode flag) |
| `automation.job.status` | `automationcore` | Agent job queue (reconciliation jobs) |
| `config.hosts` | `mmsdbconfig` | Managed host inventory |
| `config.hostClusters` | `mmsdbconfig` | Host-to-cluster mapping |

## Key Log Patterns

### Primary OM logs (`server/logs/mms0.log`)
```
PITR detected: Agent config version {V+N} > DB version {V} for group {groupId}
Set restoration mode to true for group {groupId}
CONFIG_METADATA_COLLECTION job submitted for host {hostname}
CONFIG_UPLOAD job submitted for host {hostname}
Reconciliation complete for group {groupId}
Set restoration mode to false for group {groupId}
```

### Automation Agent logs
```
# 304 response during restoration mode:
Received 304 Not Modified for config poll

# Job execution:
Running job CONFIG_METADATA_COLLECTION
Running job CONFIG_UPLOAD
```

## Key Endpoints

| Endpoint | Port | Purpose |
|---|---|---|
| Meta OM UI | http://localhost:8080 | Trigger PITR restore |
| Primary OM UI | http://localhost:8081 | Create/scale deployments |
| Primary OM appDB | mongodb://localhost:27018 | Direct appDB queries |
| Meta OM API | http://localhost:8080/api/public/v1.0/ | Snapshot/backup status |

## Files

| File | Purpose |
|---|---|
| `RECONCILIATION-POC-PLAN.md` | This document |
| `1-verify-setup.sh` | Phase 1: Verify infrastructure + topology + flags |
| `2-simulate-disaster.sh` | Phase 2: Record post-scale state, destroy appDB |
| `3-restore-and-reconcile.sh` | Phase 3: Restore, start OM, observe reconciliation |
| `4-verify-reconciliation.sh` | Phase 4: Validate config converged to pre-disaster |

## Troubleshooting

### Restoration mode not triggered
- **Check feature flag:** OM must be started with `mms.featureFlag.automation.restorationMode=enabled`
- **Check agent flag:** Agents must have `omBackupFeatureFlag=true` to send `cv` parameter
- **Check version mismatch:** Agent's `cv` must be strictly greater than AppDB config version
- **Check OM logs:** Look for "PITR detected" or "checkAndSetRestorationMode" messages

### Reconciliation not completing
- **Check agent connectivity:** Agents must be reachable for job dispatch
- **Check job queue:** Query `automationcore['automation.job.status']` for pending/failed jobs
- **Check OM logs:** Look for reconciliation orchestrator errors
- **Check agent logs:** Look for job execution errors or timeouts

### Config not converged after reconciliation
- **Check config version:** `automationcore['config.automation'].version` should match agent version
- **Check process count:** Ensure processes array reflects post-scale topology
- **Manual exit:** If stuck, manually set `restorationMode=false` on the group document (last resort)

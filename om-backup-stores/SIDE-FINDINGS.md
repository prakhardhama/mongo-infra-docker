# Backup-Stores PoC — Side Findings

Operational and architectural discoveries made during the rollback-impact PoC that don't belong in the scenario write-ups. Cross-referenced from [RESTORE-FINDINGS.md](RESTORE-FINDINGS.md).

---

## Side-finding A — Automated restore requires the agent to be PID 1

Discovered while attempting Scenario 1's first try.

**Symptom.** Triggering an Automated Restore on `primary-om-s3-meta` causes the container to exit and Meta OM to report _"We have not received any recent information from the following automation agents: primary-om-s3-meta"_. The agent never recovers on its own; restarting the container makes the agent immediately stop mongod again, killing the container in a loop.

**Root cause.** `0-setup-backing-dbs.sh` runs the container with `mongod --config …` as the entrypoint. mongod is therefore PID 1. When Meta OM stages a restore, the agent's plan is `BounceStopIfUpWithForceKill` → `MakeBackupDataAvailable` → `StartFresh`. Step 1 SIGKILLs mongod → PID 1 dies → container exits → agent dies → Meta OM loses heartbeats. Same cycle repeats on every container restart because the restore directives stay in `automationcore.config.automation`.

**Fix that worked.** Recreate the container with `--entrypoint /bin/bash … -c "tail -f /dev/null"` (the same pattern used in [om-disaster-reconciliation/3-restore-prepare.sh](../om-disaster-reconciliation/3-restore-prepare.sh)). Now `tail` is PID 1; the agent stops/starts mongod as a child process and the container survives every cycle.

**Recovery sequence we used:**

1. The first restore job (`69f181b4…`) was stuck IN_PROGRESS. We marked it as killed/broken directly in the appdb (`backupjobs.restorejobs`) and stripped 20 `backupRestore*` directives from the s3-meta process in `automationcore.config.automation` so the agent could run normally again.
2. The user re-triggered the restore from the UI (`69f185f7…`).
3. We rebuilt `primary-om-s3-meta` with the `tail` entrypoint, wiped its volume, reinstalled the agent, and the agent picked up the still-pending restore job and completed it in ~35 s.

**Action folded back into setup — DONE.** [0-setup-backing-dbs.sh](0-setup-backing-dbs.sh) now uses `--init` + `--entrypoint /bin/bash` + a small bootstrap that drops to mongod via `runuser` and starts mongod with `processManagement.fork: true`, then `exec tail -f /dev/null`. Run with the new `--rebuild` flag to migrate existing containers without wiping their volumes:

```bash
./om-backup-stores/0-setup-backing-dbs.sh --rebuild
```

After this migration, all three backing-DB containers (`primary-om-appdb`, `primary-om-s3-meta`, `primary-om-oplog-meta`) survive an agent-driven `BounceStopIfUpWithForceKill`, so Automated restores work end-to-end on each.

Two implementation gotchas worth recording:
- The `mongodb/mongodb-enterprise-server:7.0-ubi8` image has a `USER mongod` directive, so `--user 0:0` must be set on `docker run` to allow the bootstrap to `chown` and `runuser`.
- `su mongod` fails under PAM ("Authentication failure") even when called from root inside the container; `runuser -u mongod -- …` doesn't go through PAM auth and is the correct tool.

---

## Side-finding B — Disaster-recovery checklist for a Meta-OM-backs-Primary-OM topology

_Captured for [DOCSP-59303](https://jira.mongodb.org/browse/DOCSP-59303) — public docs for customers operating a Meta OM that backs up their Primary OM's appDB + S3-meta + oplog-meta._

While building this PoC we observed that **Primary OM (running locally via bazel) recovered from any disturbance in one shot, but Meta OM (running inside Docker) needed three separate fixes** before restores could be repeated. The asymmetry is purely about *where state lives*, not about OM itself, and the lessons translate directly to a real-world multi-VM customer deployment.

### State lives in three places

| State | Where it must persist on a customer VM | Symptom if missed during DR |
|---|---|---|
| **OM `gen.key`** | `/etc/mongodb-mms/gen.key` on every OM application host | Restored appDB pre-flight fails: `"The gen.key file at /etc/mongodb-mms/gen.key does not match the gen.key already used for this Ops Manager installation."` Encrypted fields in the appDB are unrecoverable. |
| **Automation Agent config** | `/etc/mongodb-mms/automation-agent.config` on every host running an agent | Agent registers under a different project (or fails to register) → managed processes become unmanaged → no backups, no monitoring; potentially "no servers found" in the deployment-import wizard. |
| **`local.clustermanager` on each managed `mongod`** | Inside the mongod's data directory itself (the `local` system database) | If a previous Automation-driven restore set `lastBackupRestoreUrl`, that string is *persisted forever* in `local.clustermanager` until the agent rewrites it. When the deployment is imported into a fresh OM, the field is reported back as part of process discovery and can stick the wizard at "Initializing Automation". |

Note that the **encrypted appDB volume itself is the easy part** — both `mongodump` and a clean filesystem snapshot work as long as the corresponding `gen.key` is also captured.

### Backup checklist (per OM machine)

For each Ops Manager host (Primary OM or Meta OM):

1. **`gen.key`**: copy `/etc/mongodb-mms/gen.key` to your backup destination. Same value required across all OM application servers in a multi-server installation.
2. **AppDB data**: either `mongodump --gzip --archive` (consistent by design) or a stop-mongod-then-tar of the data dir.
3. **OM application config** (`conf-mms.properties`, custom JVM flags, license keys, TLS certs).
4. **Custom uploaded resources** (agent installer overrides, MongoDB binary mirrors, KMIP certs).

For each Backup-Daemon machine, also:

5. **Head DB data dir** (snapshots being assembled).
6. **Filesystem-store data** if `STORAGE.FILESYSTEM` backups are configured.

For each customer mongod under management, ensure your DR procedure includes:

7. The agent config file (`/etc/mongodb-mms/automation-agent.config`) and the certificates it references.
8. A note that **any prior automated-restore directives are persisted in mongod's `local.clustermanager`** — see "Cleanup when re-importing" below.

### Restore checklist (the Meta OM ↔ Primary OM scenario)

Order matters because Meta OM has to be reachable before Primary OM's backing DBs (appDB / S3-meta / oplog-meta) can be put back under Meta OM management.

1. **Restore Meta OM application servers first**:
   - Reinstall OM RPM/DEB at the same version.
   - Restore `gen.key` to `/etc/mongodb-mms/gen.key` *before* starting the OM service. Without this, the very first preflight against the (encrypted) restored appDB will fail.
   - Restore the appDB (its replica set or standalone) from `mongodump` or filesystem snapshot.
   - Start Meta OM. Confirm the existing project, deployments, snapshot index, and API keys reappear in the UI.
2. **Restore the three Primary OM backing DBs** (appDB, S3 metadata, oplog metadata). The data alone is enough — these don't have their own `gen.key`.
3. **Restore each automation agent** by re-installing it with the *original* `automation-agent.config`. With matching `mmsGroupId` and `mmsApiKey` the agent re-attaches to the same project entry without re-registering.
4. **Restore Primary OM application servers** the same way as Meta OM (gen.key + appDB + start).
5. **Verify** by listing snapshots from the project API and triggering a no-op `Verify` on each backup configuration.

### Cleanup when re-importing a previously-managed deployment into a *new* project

This is the one that hit us hardest in the PoC. If a customer ever imports a mongod that was previously under Automation (e.g. they're migrating from one OM project to another, or rebuilding OM from scratch and choosing to *re-create* the project rather than restore the appDB), the mongod will replay stale Automation state through `local.clustermanager`.

Before the new "Add Existing Deployment" wizard is run on each previously-managed mongod, drop the relevant fields from `local.clustermanager` (connect with `retryWrites=false` because it's the `local` database):

```js
use local
const doc = db.clustermanager.findOne({});
const stale = Object.keys(doc).filter(k => /backup|restore/i.test(k));
db.clustermanager.updateOne(
  {_id: doc._id},
  {$unset: Object.fromEntries(stale.map(k => [k, ""]))}
);
```

Symptoms when this isn't done:
- "**We were unable to find any servers for your deployment**" appears persistently on the *Initializing Automation* screen of the import wizard.
- The wizard's "Review Deployment" button stays grey even after the agent reports back successfully.
- Inspecting `mmsdbautomation.importRequests` in the Meta OM appDB reveals a stale `backupRestoreUrl` on the discovered process — and that URL points to a restore job ID from the *previous* OM project, which doesn't exist in the new appDB.

### Container-specific gotcha (only relevant to Docker-based test setups)

Meta OM in our PoC runs inside `mongodb-enterprise-server`-derived containers, which means by default the OM application host's `/etc/mongodb-mms/` directory lives in the container's writable layer and is regenerated on every `docker compose down/up`. We worked around this by adding a bind mount in [docker-compose.yml](../ops-manager/docker-compose.yml):

```yaml
ops:
  volumes:
    - ./mongodb-mms-ops:/etc/mongodb-mms
```

This makes `gen.key` survive `compose` recreations — the same persistence guarantee a customer's RPM install gets for free at `/etc/mongodb-mms/gen.key` on a normal VM. Customers won't hit this; it's a Docker-PoC-only patch.

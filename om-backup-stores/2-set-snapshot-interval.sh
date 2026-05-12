#!/bin/bash

# Override the snapshot schedule on every backed-up cluster to a 1-hour base
# interval (default is 6 hours, which is too long for testing).
#
# How: backupjobs.jobs.schedule.rules has one rule per retention tier
# (base / daily / weekly / monthly). The "base" rule is the smallest interval
# (default 21600s = 6h). We rewrite it to 3600s (1h) and shrink the retention
# to 2h so we don't accumulate 6× as many snapshots.
#
# This bypasses the OM-side validator (which only allows {6,8,12,24}h via UI/
# API). The OM source explicitly tolerates manual edits — see
# SnapshotSchedule.fromDBObject: "cannot validate SnapshotSchedule on read
# because we don't want the read to fail when someone has edited the schedule
# manually in the DB".
#
# Targets both OMs:
#   Meta OM appdb         : localhost:27170  (standalone — Meta OM bundled)
#   Primary OM appdb      : localhost:27018  (RS appdb-rs)
#
# Prereqs: backup must be enabled on the deployment in the corresponding OM
# UI first; otherwise backupjobs.clusters is empty and there's nothing to
# update.
#
# After running, the backup daemon (Meta OM: bgrid in `ops`; Primary OM: bgrid
# from bazel) re-reads the schedule on its next cycle (~1 minute). Pass
# --restart-daemons to bounce the Meta OM daemon explicitly.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults — override via env
BASE_INTERVAL_SECS="${BASE_INTERVAL_SECS:-1800}"       # 30 mins
BASE_DURATION_SECS="${BASE_DURATION_SECS:-604800}"     # 7 days retention

# target name|connection URI
TARGETS=(
  "Meta OM (27170)|mongodb://host.docker.internal:27170/backupjobs?serverSelectionTimeoutMS=5000"
  "Primary OM (27018)|mongodb://host.docker.internal:27018/backupjobs?directConnection=true&serverSelectionTimeoutMS=5000"
)

RESTART_DAEMONS=false
for arg in "$@"; do
  case "$arg" in
    --restart-daemons) RESTART_DAEMONS=true ;;
    -h|--help)
      sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

update_one_target() {
  local label="$1" uri="$2"

  echo ""
  echo -e "${BLUE}━━ $label ━━${NC}"

  # Inline mongosh — print existing schedules, rewrite the smallest-interval
  # rule on each job, print the new schedules.
  #
  # Note the schedule lives on backupjobs.jobs (one doc per backed-up cluster),
  # not backupjobs.clusters. The cluster doc has snapshotSchedule for the
  # daemon's working copy, but the source-of-truth that the daemon reloads
  # via SettingsUpdateJob is the job's `schedule` field.
  docker run --rm --add-host=host.docker.internal:host-gateway mongo:7 \
    mongosh "$uri" --quiet --eval "
      const newInterval = ${BASE_INTERVAL_SECS};
      const newDuration = ${BASE_DURATION_SECS};

      const docs = db.jobs.find(
        {'schedule.rules': {\$exists: true}},
        {clusterName: 1, replicaSetName: 1, 'schedule.rules': 1, gid: 1}
      ).toArray();

      if (docs.length === 0) {
        print('  (no backup jobs found — has backup actually been enabled?)');
        quit(0);
      }

      const nowTs = Math.floor(Date.now() / 1000);
      // Align nextSnapshot to the next base-interval boundary from epoch=0,
      // because we also set schedule.reference = 0. The OM-side validator
      // (SnapshotSchedule.whenToDelete) requires (T - reference) % interval == 0
      // for the snapshot timestamp to be acceptable. With reference=0, any
      // multiple of newInterval works; the daemon picks T = next boundary >= now.
      const alignedNextTs = Math.ceil(nowTs / newInterval) * newInterval;

      docs.forEach(doc => {
        const name = doc.replicaSetName || doc.clusterName || doc._id;
        const rules = doc.schedule.rules.slice().sort((a,b) => a.interval - b.interval);
        const baseInterval = rules[0].interval;

        // 1. Update the schedule rules + reference.
        // reference=0 means snapshots happen at every newInterval mark from
        // UTC epoch, which makes alignment trivial across all retention tiers.
        if (baseInterval !== newInterval) {
          db.jobs.updateOne(
            {_id: doc._id},
            {\$set: {
              'schedule.rules.\$[base].interval': newInterval,
              'schedule.rules.\$[base].duration': newDuration,
              'schedule.reference': 0
            }},
            {arrayFilters: [{'base.interval': baseInterval}]}
          );
        } else {
          db.jobs.updateOne(
            {_id: doc._id},
            {\$set: {'schedule.reference': 0}}
          );
        }

        // 2. Reset nextSnapshot to the next aligned base boundary so the
        //    daemon takes a snapshot soon AND the timestamp is valid against
        //    whenToDelete's modulo check.
        db.jobs.updateOne(
          {_id: doc._id},
          {\$set: {nextSnapshot: Timestamp(alignedNextTs, 1)}}
        );

        const fromMsg = baseInterval !== newInterval
          ? (baseInterval/3600).toFixed(2).replace(/\.?0+$/, '') + 'h → '
          : '(already) ';
        print('  ✓ ' + name + ' — base ' + fromMsg + (newInterval/3600).toFixed(2).replace(/\.?0+$/, '') + 'h, retention ' + (newDuration/3600).toFixed(2).replace(/\.?0+$/, '') + 'h, nextSnapshot=' + new Date(alignedNextTs*1000).toISOString());
      });
    "
}

restart_meta_om_daemon() {
  echo ""
  echo -e "${BLUE}━━ Restarting Meta OM backup daemon (in ops container) ━━${NC}"
  if docker exec ops /opt/mongodb/mms/bin/mongodb-mms-backup-daemon restart 2>&1 | tail -3; then
    echo -e "  ${GREEN}✓ daemon restarted${NC}"
  else
    echo -e "  ${YELLOW}daemon restart returned non-zero (may still be fine)${NC}"
  fi
  echo ""
  echo "  Note: Primary OM's backup daemon runs in your local bazel process."
  echo "        It picks up schedule changes on its next cycle (~1 min);"
  echo "        no manual restart needed."
}

# ══════════════════════════════════════════════════════════════════════════════

echo "=== Setting base snapshot interval to ${BASE_INTERVAL_SECS}s ($((BASE_INTERVAL_SECS/3600))h) ==="

for entry in "${TARGETS[@]}"; do
  IFS='|' read -r label uri <<< "$entry"
  update_one_target "$label" "$uri"
done

if [ "$RESTART_DAEMONS" = true ]; then
  restart_meta_om_daemon
fi

echo ""
echo -e "${GREEN}=== Done ===${NC}"
echo ""
echo "If a cluster says '(no clusters with backup enabled)', enable backup on"
echo "the corresponding deployment in the OM UI first, then re-run this script."
echo ""
echo "Verify schedule was applied:"
echo "  docker run --rm --add-host=host.docker.internal:host-gateway mongo:7 \\"
echo "    mongosh 'mongodb://host.docker.internal:27170/backupjobs' --quiet --eval \\"
echo "    'db.clusters.find({},{clusterName:1,\"snapshotSchedule.rules\":1,_id:0}).toArray()'"

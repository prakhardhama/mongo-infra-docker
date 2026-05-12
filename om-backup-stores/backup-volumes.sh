#!/bin/bash

# Disaster-recovery backup for the whole OM-stack on Docker Desktop.
#
# What it captures into a single dated directory under ~/om-backups/<UTC>/:
#   1. dumps/      — mongodump --gzip --archive of each mongod (Meta OM + 3 backing DBs)
#   2. volumes/    — raw tar.gz of every named volume attached to our containers
#   3. repo/       — copy of om-backup-stores/ + om-docker/ (scripts, conf, downloads)
#   4. manifest.txt — what's in the backup, sizes, container info
#
# This bundle is sufficient to rebuild the stack on a fresh Docker Desktop install:
#   1. extract repo/ back into your mongo-infra-docker checkout (or use it directly)
#   2. run restore-volumes.sh <backup-dir>
#   3. run repo/om-docker/quick-start.sh + repo/om-backup-stores/0-setup-backing-dbs.sh
#
# Override the destination dir via BACKUP_DIR=…  Otherwise defaults to
# ~/om-backups/<YYYYMMDD_HHMM_UTC>/.

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DATE=$(date -u +%Y%m%d_%H%M)
BACKUP_DIR="${BACKUP_DIR:-$HOME/om-backups/$DATE}"

# Mongods to dump — addressed by their host-published port. We use a sidecar
# mongo:7 container for mongodump so we don't depend on what's installed inside
# the target container (Meta OM's `ops` image, for example, strips client tools).
#   port|label
declare -a MONGOD_TARGETS=(
  "27170|meta-om-appdb"        # Meta OM's bundled appdb (CRITICAL — nothing else backs this up)
  "27018|appdb-rs"
  "27019|s3-meta-rs"
  "27020|oplog-meta-rs"
)

# Containers whose attached volumes we want to capture
declare -a VOLUME_CONTAINERS=(
  ops
  node1
  primary-om-appdb
  primary-om-s3-meta
  primary-om-oplog-meta
)

# ── Set up destination ──────────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"/{dumps,volumes,repo,secrets}
echo "=== Backing up to $BACKUP_DIR ==="
echo ""

MANIFEST="$BACKUP_DIR/manifest.txt"
{
  echo "OM-Stack Backup Manifest"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Host:      $(hostname)"
  echo "Docker:    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"
  echo ""
} > "$MANIFEST"

# ── 1. Logical dumps via mongodump ──────────────────────────────────────────
echo -e "${BLUE}1. mongodump (logical backups)${NC}"
echo "──────────────────────────────────"
echo "[mongodump]" >> "$MANIFEST"

for entry in "${MONGOD_TARGETS[@]}"; do
  IFS='|' read -r port label <<< "$entry"
  out_name="${label}.archive.gz"
  echo "  host.docker.internal:$port → $out_name"

  # Use a sidecar mongo:7 container to run mongodump. directConnection=true
  # so the URI works even when the target is a 1-node RS whose member host
  # isn't routable from inside the sidecar.
  if docker run --rm \
       --add-host=host.docker.internal:host-gateway \
       -v "$BACKUP_DIR/dumps:/dumps" \
       mongo:7 \
       mongodump --uri "mongodb://host.docker.internal:${port}/?directConnection=true&serverSelectionTimeoutMS=10000" \
       --archive="/dumps/${out_name}" --gzip >/dev/null 2>&1; then
    size=$(du -h "$BACKUP_DIR/dumps/${out_name}" 2>/dev/null | cut -f1)
    echo -e "    ${GREEN}✓ $size${NC}"
    echo "  $label  $size" >> "$MANIFEST"
  else
    echo -e "    ${RED}✗ mongodump failed${NC}"
    echo "  $label FAILED" >> "$MANIFEST"
  fi
done

echo ""

# ── 1b. Capture ops's gen.key ──────────────────────────────────────────────
echo -e "${BLUE}1b. Capturing /etc/mongodb-mms/gen.key from ops${NC}"
echo "──────────────────────────────────────────────────"
echo "" >> "$MANIFEST"
echo "[secrets]" >> "$MANIFEST"
if docker ps --format '{{.Names}}' | grep -q "^ops$"; then
  if docker cp ops:/etc/mongodb-mms/gen.key "$BACKUP_DIR/secrets/ops-gen.key" 2>/dev/null; then
    chmod 600 "$BACKUP_DIR/secrets/ops-gen.key"
    sz=$(wc -c < "$BACKUP_DIR/secrets/ops-gen.key")
    echo -e "  ${GREEN}✓ ops-gen.key ($sz bytes)${NC}"
    echo "  ops-gen.key  ${sz}B" >> "$MANIFEST"
  else
    echo -e "  ${RED}✗ failed to extract gen.key from ops${NC}"
    echo "  ops-gen.key FAILED — Meta OM appdb will be unrecoverable!" >> "$MANIFEST"
  fi
else
  echo -e "  ${YELLOW}⚠ ops not running — skipping gen.key${NC}"
  echo "  ops-gen.key SKIPPED" >> "$MANIFEST"
fi
echo ""

# ── 2. Raw volume tar.gz (containers stopped → consistent journals) ────────
echo -e "${BLUE}2. Raw volume tarballs (containers stopped to avoid WT journal corruption)${NC}"
echo "──────────────────────────────────────────────────────────────────────────"
echo "" >> "$MANIFEST"
echo "[volumes]" >> "$MANIFEST"

# Note which containers were running so we restart them after
declare -a TO_RESTART=()
for c in ops node1 primary-om-appdb primary-om-s3-meta primary-om-oplog-meta; do
  if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
    TO_RESTART+=("$c")
  fi
done

if [ ${#TO_RESTART[@]} -gt 0 ]; then
  echo -e "  ${YELLOW}Stopping ${#TO_RESTART[@]} containers for consistent tarballs (~30 s downtime)${NC}"
  for c in "${TO_RESTART[@]}"; do
    docker stop "$c" >/dev/null 2>&1 && echo "    ⏸  $c" || echo "    ✗ failed to stop $c"
  done
  echo ""
fi

# Discover volumes attached to our containers (skip anonymous /data/configdb ones)
declare -a VOLUMES_SEEN=()
for c in "${VOLUME_CONTAINERS[@]}"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    continue
  fi
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    # Skip anonymous mongo-image volumes for /data/configdb (40-char hex names, no data we need)
    if [[ "$v" =~ ^[a-f0-9]{60,}$ ]]; then
      continue
    fi
    # Dedup
    if [[ ! " ${VOLUMES_SEEN[*]} " =~ " ${v} " ]]; then
      VOLUMES_SEEN+=("$v")
    fi
  done < <(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{println}}{{end}}{{end}}' 2>/dev/null)
done

if [ ${#VOLUMES_SEEN[@]} -eq 0 ]; then
  echo -e "  ${YELLOW}⚠ No named volumes found across our containers${NC}"
fi

for v in "${VOLUMES_SEEN[@]}"; do
  out="$BACKUP_DIR/volumes/${v}.tar.gz"
  echo "  $v → $(basename "$out")"
  if docker run --rm -v "$v:/src:ro" -v "$BACKUP_DIR/volumes:/backup" alpine \
       tar czf "/backup/${v}.tar.gz" -C /src . 2>/dev/null; then
    size=$(du -h "$out" 2>/dev/null | cut -f1)
    echo -e "    ${GREEN}✓ $size${NC}"
    echo "  $v  $size" >> "$MANIFEST"
  else
    echo -e "    ${RED}✗ tar failed${NC}"
    echo "  $v FAILED" >> "$MANIFEST"
  fi
done

# Restart containers we stopped
if [ ${#TO_RESTART[@]} -gt 0 ]; then
  echo ""
  echo -e "  ${YELLOW}Restarting containers${NC}"
  for c in "${TO_RESTART[@]}"; do
    docker start "$c" >/dev/null 2>&1 && echo "    ▶  $c" || echo "    ✗ failed to start $c"
  done

  # Backing-DB agents are started via `docker exec -d` (not by the container's
  # entrypoint), so they don't auto-restart. Re-run the restart-agents script.
  if [ -x "$SCRIPT_DIR/1-restart-agents.sh" ]; then
    echo ""
    echo -e "  ${YELLOW}Restarting backing-DB agents (mongod auto-starts via bootstrap; agents don't)${NC}"
    sleep 5  # let mongods come up first
    "$SCRIPT_DIR/1-restart-agents.sh" 2>&1 | grep -E "^\[|✓|✗" | head -20
  fi
  echo ""
  echo "  (Meta OM Java will take ~3 min to be HTTP-ready again — see ./3-verify-setup.sh)"
fi

echo ""

# ── 3. Repo files (scripts, configs, dockerfiles, downloads) ────────────────
echo -e "${BLUE}3. Repo snapshot${NC}"
echo "──────────────────"
echo "" >> "$MANIFEST"
echo "[repo]" >> "$MANIFEST"

for sub in om-backup-stores ops-manager; do
  if [ -d "$REPO_ROOT/$sub" ]; then
    echo "  $sub/"
    rsync -a --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' \
      "$REPO_ROOT/$sub" "$BACKUP_DIR/repo/" 2>/dev/null
    size=$(du -sh "$BACKUP_DIR/repo/$sub" 2>/dev/null | cut -f1)
    echo -e "    ${GREEN}✓ $size${NC}"
    echo "  $sub  $size" >> "$MANIFEST"
  else
    echo -e "  ${YELLOW}⚠ $REPO_ROOT/$sub not found — skipping${NC}"
  fi
done

echo ""

# ── 4. Completeness check + summary ─────────────────────────────────────────
echo -e "${BLUE}4. Completeness check${NC}"
echo "─────────────────────────"

# Critical-file checklist — without these, the backup is not seamlessly recoverable
declare -a CHECKS=(
  "secrets/ops-gen.key|Meta OM gen.key — required to decrypt the appdb (admin user, project, deployments)"
  "volumes/ops-manager_meta-om-appdb-data.tar.gz|Meta OM appdb volume (admin/project/deployments live here)"
  "dumps/meta-om-appdb.archive.gz|Meta OM mongodump (consistent fallback)"
  "repo/ops-manager/mongodb-mms/automation-agent.config|node1's agent creds (mmsGroupId + mmsApiKey for the project)"
  "repo/ops-manager/docker-compose.yml|Stack definition (ops/node1/etc.)"
  "repo/ops-manager/certs|Stack TLS certificates (bind-mounted)"
  "repo/om-backup-stores/KEYS.md|API keys for our scripts"
  "repo/om-backup-stores/0-setup-backing-dbs.sh|Backing-DB setup script"
  "repo/om-backup-stores/restore-volumes.sh|Restore script (so backup is self-restoring)"
)

ALL_OK=true
echo "" >> "$MANIFEST"
echo "[completeness]" >> "$MANIFEST"
for entry in "${CHECKS[@]}"; do
  IFS='|' read -r path desc <<< "$entry"
  if [ -e "$BACKUP_DIR/$path" ]; then
    echo -e "  ${GREEN}✓${NC} $path  — $desc"
    echo "  OK   $path" >> "$MANIFEST"
  else
    echo -e "  ${RED}✗${NC} $path  — $desc"
    echo "  MISSING $path" >> "$MANIFEST"
    ALL_OK=false
  fi
done

echo ""
echo -e "${BLUE}Summary${NC}"
echo "──────────"
total=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
echo "" >> "$MANIFEST"
echo "Total: $total" >> "$MANIFEST"
if [ "$ALL_OK" = true ]; then
  echo -e "  ${GREEN}✓ Backup ready at: $BACKUP_DIR${NC} (all critical files present)"
else
  echo -e "  ${YELLOW}⚠ Backup at: $BACKUP_DIR${NC} (some critical files missing — see above)"
fi
echo "  Total size: $total"
echo ""
echo "  Restore with:  ./om-backup-stores/restore-volumes.sh $BACKUP_DIR"
echo "  Add --sync-host-repo to also overwrite ~/mongo-infra-docker/{ops-manager,om-backup-stores}"
echo "  with the backup's contents (useful on a fresh-machine recovery)."

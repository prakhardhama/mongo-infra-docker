#!/bin/bash

# Disaster-recovery restore for the OM-stack.
#
# Inverse of backup-volumes.sh. Takes a backup dir produced by that script
# and brings the entire stack back to a working state, end-to-end:
#
#   1. Stop & remove our containers (ops, node1, primary-om-* if present)
#   2. Wipe existing named volumes and rehydrate them from volumes/*.tar.gz
#   3. docker compose up the Meta OM stack (ops + node1) using the embedded repo
#   4. Poll Meta OM HTTP until it's actually responding (skips quick-start.sh's
#      blind 5-minute sleep, which is only there for the initial setup)
#   5. Run the embedded 0-setup-backing-dbs.sh — with volumes already restored
#      it just brings the 3 backing DBs up against existing data
#   6. Run 3-verify-setup.sh for sanity
#
# Usage:
#   ./restore-volumes.sh <backup-dir>            # asks for confirmation
#   ./restore-volumes.sh <backup-dir> --yes      # no confirmation, wipes immediately
#   ./restore-volumes.sh <backup-dir> --skip-build  # don't run docker compose build
#                                                    (use cached images from this machine)

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

if [ $# -lt 1 ]; then
  echo "usage: $0 <backup-dir> [--yes] [--skip-build]"
  echo ""
  echo "Latest backups under ~/om-backups/:"
  ls -1d "$HOME"/om-backups/*/ 2>/dev/null | sort | tail -5 | sed 's|^|  |'
  exit 1
fi

BACKUP_DIR="$1"; shift
YES=false
SKIP_BUILD=false
SYNC_HOST_REPO=false
HOST_REPO_DIR="${HOST_REPO_DIR:-$HOME/mongo-infra-docker}"
for arg in "$@"; do
  case "$arg" in
    --yes) YES=true ;;
    --skip-build) SKIP_BUILD=true ;;
    --sync-host-repo) SYNC_HOST_REPO=true ;;
  esac
done

if [ ! -d "$BACKUP_DIR" ]; then
  echo -e "${RED}✗ Backup dir not found: $BACKUP_DIR${NC}"
  exit 1
fi
if [ ! -d "$BACKUP_DIR/volumes" ]; then
  echo -e "${RED}✗ $BACKUP_DIR has no volumes/ subdir — not a valid backup${NC}"
  exit 1
fi
if [ ! -d "$BACKUP_DIR/repo/ops-manager" ]; then
  echo -e "${RED}✗ $BACKUP_DIR has no repo/ops-manager — Meta OM compose missing${NC}"
  exit 1
fi
if [ ! -d "$BACKUP_DIR/repo/om-backup-stores" ]; then
  echo -e "${RED}✗ $BACKUP_DIR has no repo/om-backup-stores — backing-DB scripts missing${NC}"
  exit 1
fi
if [ ! -f "$BACKUP_DIR/secrets/ops-gen.key" ]; then
  echo -e "${YELLOW}⚠ $BACKUP_DIR/secrets/ops-gen.key missing.${NC}"
  echo "   Without this, Meta OM appdb data is encrypted with a key we don't have."
  echo "   The pre-flight check will fail and the only recovery is to wipe Meta OM"
  echo "   appdb and lose its state. Backups taken before the gen.key fix lack this."
  echo ""
  read -p "Proceed anyway and accept losing Meta OM state? Type 'yes' to continue: " skip_genkey
  [ "$skip_genkey" != "yes" ] && exit 1
fi

# ──────────────────────────────────────────────────────────────────────────
# Plan + confirmation
# ──────────────────────────────────────────────────────────────────────────
echo "=== Restore plan from $BACKUP_DIR ==="
echo ""
[ -f "$BACKUP_DIR/manifest.txt" ] && head -10 "$BACKUP_DIR/manifest.txt" | sed 's/^/  /'
echo ""

declare -a TARBALLS=("$BACKUP_DIR"/volumes/*.tar.gz)
if [ ! -e "${TARBALLS[0]}" ]; then
  echo -e "${RED}✗ No tarballs in $BACKUP_DIR/volumes/${NC}"
  exit 1
fi

declare -a VOLUMES=()
for t in "${TARBALLS[@]}"; do
  VOLUMES+=("$(basename "$t" .tar.gz)")
done

echo -e "${BLUE}Will:${NC}"
echo "  1. stop+remove containers: ops, node1, primary-om-*"
echo "  2. wipe + rehydrate ${#VOLUMES[@]} volumes from tarballs"
for v in "${VOLUMES[@]}"; do
  size=$(du -h "$BACKUP_DIR/volumes/${v}.tar.gz" 2>/dev/null | cut -f1)
  echo "       $v  ($size compressed)"
done
echo "  3. docker compose up -d ops node1 (Meta OM)"
[ "$SKIP_BUILD" = false ] && echo "       (will build images if not cached)"
echo "  4. wait for Meta OM HTTP on :8080"
echo "  5. run 0-setup-backing-dbs.sh to bring up primary-om-* containers"
echo "  6. run 3-verify-setup.sh for sanity"
echo ""

if [ "$YES" = false ]; then
  echo -e "${YELLOW}This is destructive (step 2 deletes existing volumes).${NC}"
  read -p "Proceed? Type 'restore' to confirm: " confirm
  if [ "$confirm" != "restore" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# ──────────────────────────────────────────────────────────────────────────
# 1. Stop+remove containers
# ──────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}1. Stopping containers${NC}"
for c in primary-om-appdb primary-om-s3-meta primary-om-oplog-meta node1 ops; do
  if docker ps -a --format '{{.Names}}' | grep -q "^${c}$"; then
    docker stop "$c" 2>/dev/null && echo "  stopped: $c" || true
    docker rm "$c" 2>/dev/null && echo "  removed: $c" || true
  fi
done

# ──────────────────────────────────────────────────────────────────────────
# 2. Wipe + rehydrate volumes
# ──────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}2. Restoring volumes${NC}"
for v in "${VOLUMES[@]}"; do
  echo "  $v"
  docker volume rm "$v" 2>/dev/null && echo "    ✓ wiped existing" || echo "    (no existing volume)"
  docker volume create "$v" >/dev/null
  if docker run --rm -v "$v:/dst" -v "$BACKUP_DIR/volumes:/backup:ro" alpine \
       sh -c "cd /dst && tar xzf /backup/${v}.tar.gz" 2>/dev/null; then
    size=$(docker run --rm -v "$v:/x" alpine sh -c "du -sh /x | cut -f1")
    echo -e "    ${GREEN}✓ restored ($size)${NC}"
  else
    echo -e "    ${RED}✗ restore failed for $v${NC}"
    exit 1
  fi
done

# ──────────────────────────────────────────────────────────────────────────
# 2b. (Optional) Sync backup repo back to user's working dir
#     Useful for a fresh-machine recovery where ~/mongo-infra-docker doesn't
#     exist or is stale relative to the backup. After this, the user's normal
#     working dir reflects the restored state.
# ──────────────────────────────────────────────────────────────────────────
if [ "$SYNC_HOST_REPO" = true ]; then
  echo ""
  echo -e "${BLUE}2b. Syncing backup repo → $HOST_REPO_DIR${NC}"
  for sub in ops-manager om-backup-stores; do
    if [ -d "$BACKUP_DIR/repo/$sub" ]; then
      mkdir -p "$HOST_REPO_DIR/$sub"
      rsync -a "$BACKUP_DIR/repo/$sub/" "$HOST_REPO_DIR/$sub/"
      echo -e "  ${GREEN}✓ $HOST_REPO_DIR/$sub${NC}"
    fi
  done
fi

# ──────────────────────────────────────────────────────────────────────────
# 3. docker compose up Meta OM
# ──────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}3. Starting Meta OM (ops + node1)${NC}"
# Prefer the LIVE working dir for compose. The compose file uses relative bind
# mounts (./mongodb-mms, ./certs, ./mongodb-mms-ops) — running compose from
# different working dirs anchors those mounts to different host paths, which
# leads to confusion later when the user edits files at one path and the
# container reads from another. The live dir is the one the user will keep
# editing. Fall back to backup dir only if live doesn't exist (fresh machine).
if [ -d "$HOST_REPO_DIR/ops-manager" ]; then
  # Make sure the live dir has the bind-mount targets the compose file expects.
  # Auto-sync ops-manager/ from the backup if --sync-host-repo wasn't passed but
  # critical bind-mount targets are missing.
  if [ ! -f "$HOST_REPO_DIR/ops-manager/mongodb-mms/automation-agent.config" ] || \
     [ ! -d "$HOST_REPO_DIR/ops-manager/certs" ]; then
    echo "  live dir missing bind-mount targets — auto-syncing from backup"
    rsync -a "$BACKUP_DIR/repo/ops-manager/" "$HOST_REPO_DIR/ops-manager/"
  fi
  COMPOSE_DIR="$HOST_REPO_DIR/ops-manager"
  echo "  using live dir: $COMPOSE_DIR"
else
  echo "  (live dir $HOST_REPO_DIR/ops-manager doesn't exist — falling back to backup repo)"
  COMPOSE_DIR="$BACKUP_DIR/repo/ops-manager"
fi
if [ "$SKIP_BUILD" = true ]; then
  (cd "$COMPOSE_DIR" && docker compose -p ops-manager up -d ops node1) || {
    echo -e "${RED}✗ docker compose up failed${NC}"
    exit 1
  }
else
  (cd "$COMPOSE_DIR" && docker compose -p ops-manager up -d --build ops node1) || {
    echo -e "${RED}✗ docker compose up --build failed${NC}"
    echo "  If this is a fresh Docker Desktop install, ensure $COMPOSE_DIR/downloads/ has the RPMs/JDK."
    exit 1
  }
fi

# ──────────────────────────────────────────────────────────────────────────
# 3b. Inject ops's saved gen.key BEFORE Meta OM Java pre-flights
# ──────────────────────────────────────────────────────────────────────────
if [ -f "$BACKUP_DIR/secrets/ops-gen.key" ]; then
  echo ""
  echo -e "${BLUE}3b. Restoring gen.key into ops${NC}"
  # Stop the failing Meta OM Java service (it pre-flights gen.key in <15s and
  # marks the systemd unit failed; we need to put the right gen.key in place
  # then `systemctl restart` to re-trigger pre-flight with the matching key).
  docker exec ops bash -c '
    systemctl stop mongodb-mms 2>/dev/null || true
    # mongod inside ops should keep running — Meta OM restarts will reconnect to it
  ' 2>/dev/null
  docker cp "$BACKUP_DIR/secrets/ops-gen.key" ops:/etc/mongodb-mms/gen.key
  docker exec ops bash -c 'chown mongodb-mms:mongodb-mms /etc/mongodb-mms/gen.key && chmod 600 /etc/mongodb-mms/gen.key'
  docker exec ops bash -c 'systemctl start mongodb-mms' 2>/dev/null
  echo -e "  ${GREEN}✓ gen.key restored, Meta OM Java service restarted${NC}"
fi

# ──────────────────────────────────────────────────────────────────────────
# 4. Wait for Meta OM HTTP
# ──────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}4. Waiting for Meta OM HTTP (up to 5 min)${NC}"
WAITED=0
MAX_WAIT=300
INTERVAL=5
while [ $WAITED -lt $MAX_WAIT ]; do
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8080" 2>/dev/null || echo "000")
  if [[ "$HTTP" =~ ^(200|302|303)$ ]]; then
    echo -e "  ${GREEN}✓ Meta OM responding (HTTP $HTTP) after ${WAITED}s${NC}"
    break
  fi
  if [ $((WAITED % 30)) -eq 0 ] && [ $WAITED -gt 0 ]; then
    echo "  ...still waiting (${WAITED}s, current: HTTP $HTTP)"
  fi
  sleep $INTERVAL
  WAITED=$((WAITED + INTERVAL))
done

if [ $WAITED -ge $MAX_WAIT ]; then
  echo -e "  ${RED}✗ Meta OM did not respond within ${MAX_WAIT}s${NC}"
  echo "    Check: docker logs ops"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────
# 5. Bring up backing DBs (containers + agents) from the embedded script
# ──────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}5. Bringing up backing DBs${NC}"
SETUP_SCRIPT="$BACKUP_DIR/repo/om-backup-stores/0-setup-backing-dbs.sh"
if [ ! -x "$SETUP_SCRIPT" ]; then
  chmod +x "$SETUP_SCRIPT"
fi
# No --fresh: existing volumes (just restored) are reused; mongods come up against existing data
"$SETUP_SCRIPT" || {
  echo -e "${RED}✗ 0-setup-backing-dbs.sh failed${NC}"
  exit 1
}

# Make sure agents are running (the setup script handles it, but be defensive)
"$BACKUP_DIR/repo/om-backup-stores/1-restart-agents.sh" 2>&1 | tail -10

# ──────────────────────────────────────────────────────────────────────────
# 6. Verify
# ──────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}6. Verifying${NC}"
VERIFY="$BACKUP_DIR/repo/om-backup-stores/3-verify-setup.sh"
if [ -x "$VERIFY" ]; then
  "$VERIFY" 2>&1 | tail -22
else
  chmod +x "$VERIFY" 2>/dev/null && "$VERIFY" 2>&1 | tail -22
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Restore complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Reminder: Primary OM (the bazel server) is NOT brought up by this script."
echo "Start it manually if needed:"
echo "  cd /Users/prakhar.dhama/ops-manager"
echo "  bazel run --server_env=hosted //server:mms -- \\"
echo "    --jvm_flag=-Dmms.featureFlag.automation.restorationMode=enabled"

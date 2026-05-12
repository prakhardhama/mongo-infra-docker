#!/bin/bash

# Restart Meta OM automation agents inside the backing-DB containers.
#
# The agents are started via `docker exec -d` (not via the container entrypoint
# — that's mongod), so a container restart leaves mongod running but the agent
# gone. This script (re)starts the agent inside each of:
#
#   primary-om-appdb       (port 27018)
#   primary-om-s3-meta     (port 27019)
#   primary-om-oplog-meta  (port 27020)
#
# Idempotent. Pass --force to restart agents that are already running.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# container|port (the same instance table used by 0-setup-backing-dbs.sh)
INSTANCES=(
  "primary-om-appdb|27018"
  "primary-om-s3-meta|27019"
  "primary-om-oplog-meta|27020"
)

FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    -h|--help)
      sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

restart_one() {
  local container="$1" port="$2"

  echo ""
  echo -e "${BLUE}━━ $container (port $port) ━━${NC}"

  # 1. Container must exist and be running.
  if ! docker ps --filter "name=^${container}$" --filter "status=running" --format "{{.Names}}" | grep -q "^${container}$"; then
    echo -e "  ${RED}✗ container not running — skipping${NC}"
    echo "    start it with: docker start $container  (or re-run 0-setup-backing-dbs.sh)"
    return 1
  fi

  # 2. mongod is the container entrypoint, so it should already be up. Verify.
  if ! docker exec "$container" mongosh --port "$port" --quiet --eval \
      "db.adminCommand({ping:1})" 2>/dev/null | grep -q "ok"; then
    echo -e "  ${RED}✗ mongod is not responding on :${port}${NC}"
    echo "    check: docker logs $container"
    return 1
  fi
  echo -e "  ${GREEN}✓ mongod up on :${port}${NC}"

  # 3. Agent binary + config must already be installed (by 0-setup-backing-dbs.sh).
  if ! docker exec "$container" test -f /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent; then
    echo -e "  ${RED}✗ agent binary missing${NC} — run 0-setup-backing-dbs.sh first"
    return 1
  fi
  if ! docker exec "$container" test -f /etc/mongodb-mms/automation-agent.config; then
    echo -e "  ${RED}✗ agent config missing${NC} — run 0-setup-backing-dbs.sh first"
    return 1
  fi

  # 4. If the agent is already running, only restart when --force is set.
  if docker exec "$container" pgrep -f mongodb-mms-automation-agent >/dev/null 2>&1; then
    if [ "$FORCE" = false ]; then
      echo -e "  ${GREEN}✓ agent already running (pass --force to restart)${NC}"
      return 0
    fi
    echo -e "  ${YELLOW}stopping existing agent…${NC}"
    docker exec -u root "$container" bash -c "
      pkill -f mongodb-mms-automation-agent 2>/dev/null || true
      sleep 2
      pkill -9 -f mongodb-mms-automation-agent 2>/dev/null || true
    " || true
  fi

  # Clean any stale lockfile (left over from a SIGKILL or container OOM).
  docker exec -u root "$container" rm -f /tmp/mongodb-mms-automation.lock 2>/dev/null || true

  # Ensure ownership is mongod:mongod — the agent must run as the same user as mongod.
  docker exec -u root "$container" bash -c "
    chown -R mongod:mongod /opt/mongodb-mms-automation /etc/mongodb-mms \
      /var/log/mongodb-mms-automation /var/lib/mongodb-mms-automation 2>/dev/null || true
  "

  # 5. Start the agent.
  docker exec -d -u mongod "$container" \
    /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent \
    -f /etc/mongodb-mms/automation-agent.config

  sleep 5

  if docker exec "$container" pgrep -f mongodb-mms-automation-agent >/dev/null 2>&1; then
    local agent_user pid
    pid=$(docker exec "$container" pgrep -f mongodb-mms-automation-agent | head -1)
    agent_user=$(docker exec "$container" ps -o user= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    echo -e "  ${GREEN}✓ agent started (pid=$pid, user=$agent_user)${NC}"
  else
    echo -e "  ${RED}✗ agent failed to start${NC}"
    echo "    docker exec $container tail -30 /var/log/mongodb-mms-automation/automation-agent.log"
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════════

echo "=== Restart backing-DB Meta OM agents ==="

failures=0
for entry in "${INSTANCES[@]}"; do
  IFS='|' read -r container port <<< "$entry"
  restart_one "$container" "$port" || failures=$((failures + 1))
done

echo ""
if [ "$failures" -eq 0 ]; then
  echo -e "${GREEN}=== All ${#INSTANCES[@]} agents OK ===${NC}"
else
  echo -e "${RED}=== $failures of ${#INSTANCES[@]} agents had problems ===${NC}"
  exit 1
fi

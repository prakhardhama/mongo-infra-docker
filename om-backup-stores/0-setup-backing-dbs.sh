#!/bin/bash

# Setup Primary OM backing databases for full backup PoC.
#
# Creates 3 MongoDB 7.0 Enterprise replica-set containers, each with the Meta OM
# automation agent installed so Meta OM can manage and back them up:
#
#   1. primary-om-appdb       (port 27018, RS appdb-rs)       — Primary OM appDB
#   2. primary-om-s3-meta     (port 27019, RS s3-meta-rs)     — S3 backup store metadata
#   3. primary-om-oplog-meta  (port 27020, RS oplog-meta-rs)  — oplog store metadata
#
# Each container is connected to the Meta OM Docker network (ops-manager_main),
# initialized as a single-node replica set using its Docker network IP, and
# has the Meta OM agent installed and running as the mongod user.
#
# Prereqs:
#   - Meta OM up at http://localhost:8080 (containers `ops` and `node1` running)
#   - The `node1` container has a working agent config we can copy credentials from
#
# Idempotent: re-running skips already-healthy instances. Pass --fresh to wipe
# all backing-DB containers and volumes (including legacy mongodb-ops-manager)
# and rebuild from scratch.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MONGODB_IMAGE="mongodb/mongodb-enterprise-server:7.0-ubi8"
DOCKER_NETWORK="ops-manager_main"
META_OM_BASE_URL="http://ops.om.internal:8080"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/backing-db-config"

# Instance definitions: name|host_port|replica_set|description
INSTANCES=(
  "primary-om-appdb|27018|appdb-rs|Primary OM appDB"
  "primary-om-s3-meta|27019|s3-meta-rs|Primary OM S3 backup store metadata"
  "primary-om-oplog-meta|27020|oplog-meta-rs|Primary OM oplog store metadata"
)

# Legacy container/volumes from the old single-appdb PoC — wiped on --fresh
LEGACY_CONTAINERS=("mongodb-ops-manager")
LEGACY_VOLUMES=("primary-om-appdb" "primary-om-appdb-log")

FRESH=false
REBUILD=false
for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH=true ;;
    --rebuild) REBUILD=true ;;
    -h|--help)
      sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
      cat <<EOF

Flags:
  --fresh     Wipe containers AND volumes; rebuild from scratch.
  --rebuild   Stop+remove existing containers (volumes preserved) and
              recreate with the current entrypoint config. Use this when
              migrating an existing setup to a new entrypoint pattern
              (e.g. enabling agent-driven restore).
EOF
      exit 0
      ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

wait_for_mongod() {
  local container="$1" port="$2"
  echo "  Waiting for mongod in $container (port $port)..."
  for i in $(seq 1 12); do
    sleep 5
    if docker exec "$container" mongosh --port "$port" --quiet --eval "db.adminCommand({ping:1})" 2>/dev/null | grep -q "ok"; then
      echo -e "  ${GREEN}✓ mongod is up${NC}"
      return 0
    fi
    [ "$i" -eq 12 ] && echo -e "  ${RED}✗ mongod did not become ready — check: docker logs $container${NC}" && exit 1
  done
}

ensure_network() {
  local container="$1"
  if ! docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
    echo -e "  ${RED}✗ Network $DOCKER_NETWORK not found — is Meta OM running?${NC}"
    echo "    Start Meta OM with om-docker/quick-start.sh first."
    exit 1
  fi
  docker network connect "$DOCKER_NETWORK" "$container" 2>/dev/null || true
  docker inspect "$container" \
    --format "{{(index .NetworkSettings.Networks \"$DOCKER_NETWORK\").IPAddress}}"
}

ensure_rs_member_hostname() {
  local container="$1" host_port="$2"
  # RS member uses the container's Docker DNS name. From inside ops-manager_main
  # this resolves to the container's docker-net IP — unique per backing DB,
  # so Meta OM treats each as a separate Server (different rcid). Primary OM
  # on the host doesn't follow this hostname because the URI uses
  # host.docker.internal:<port> with directConnection=true.
  local current_host expected_host="${container}:${host_port}"
  current_host=$(docker exec "$container" mongosh --port "$host_port" --quiet --eval \
    "try { print(rs.conf().members[0].host) } catch(e) { print('') }" 2>/dev/null | tr -d '[:space:]')
  if [ "$current_host" != "$expected_host" ]; then
    echo -e "  ${YELLOW}Reconfiguring RS member: $current_host → $expected_host${NC}"
    docker exec "$container" mongosh --port "$host_port" --quiet --eval "
      cfg = rs.conf();
      cfg.members[0].host = '$expected_host';
      rs.reconfig(cfg, {force: true});
    " >/dev/null 2>&1
    sleep 2
  fi
  echo -e "  ${GREEN}✓ RS member: $expected_host${NC}"
}

write_mongod_conf() {
  local container="$1" replica_set="$2" port="$3"
  local conf_file="$CONFIG_DIR/${container}.conf"
  cat > "$conf_file" << EOF
# mongod.conf for $container

storage:
  dbPath: /data/db

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: $port
  bindIp: 0.0.0.0

replication:
  replSetName: $replica_set

# Fork so the container's bootstrap script can start mongod and then exec into
# 'tail -f /dev/null' (needed so the container survives the agent stopping
# mongod for an automated restore).
processManagement:
  fork: true
EOF
  echo "$conf_file"
}

# ── Agent install ─────────────────────────────────────────────────────────────

# Install agent binaries inside the container (one-time)
install_agent_binaries() {
  local container="$1"

  if docker exec "$container" test -f /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent 2>/dev/null; then
    echo -e "  ${GREEN}✓ Agent binary already installed${NC}"
    return 0
  fi

  local agent_tarball
  agent_tarball=$(docker exec ops bash -c \
    "ls /opt/mongodb/mms/agent/automation/*aarch64.tar.gz 2>/dev/null | head -1" || echo "")
  if [ -z "$agent_tarball" ]; then
    echo -e "  ${RED}✗ No ARM64 agent tarball in Meta OM container${NC}"
    echo "    Expected: /opt/mongodb/mms/agent/automation/*aarch64.tar.gz"
    exit 1
  fi
  echo "  Found agent: $(basename "$agent_tarball")"

  docker cp "ops:$agent_tarball" "/tmp/mongodb-agent.tar.gz"
  docker cp /tmp/mongodb-agent.tar.gz "$container":/tmp/mongodb-agent.tar.gz

  docker exec -u root "$container" bash -c "
    set -e
    yum install -y hostname procps-ng >/dev/null 2>&1 || true

    cd /tmp
    rm -rf mongodb-mms-automation-agent-* 2>/dev/null || true
    tar -xzf mongodb-agent.tar.gz

    EXTRACTED_DIR=\$(ls -d mongodb-mms-automation-agent-* 2>/dev/null | head -1)
    if [ -z \"\$EXTRACTED_DIR\" ]; then
      echo 'ERROR: extracted agent directory not found'
      exit 1
    fi

    mkdir -p /opt/mongodb-mms-automation/bin
    cp -f \"\$EXTRACTED_DIR/mongodb-mms-automation-agent\" /opt/mongodb-mms-automation/bin/
    cp -f \"\$EXTRACTED_DIR/fatallogger\" /opt/mongodb-mms-automation/bin/ 2>/dev/null || true
    chmod +x /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent
    [ -f /opt/mongodb-mms-automation/bin/fatallogger ] && chmod +x /opt/mongodb-mms-automation/bin/fatallogger

    mkdir -p /etc/mongodb-mms /var/log/mongodb-mms-automation /var/lib/mongodb-mms-automation
    chown -R mongod:mongod /opt/mongodb-mms-automation /etc/mongodb-mms \
      /var/log/mongodb-mms-automation /var/lib/mongodb-mms-automation

    rm -rf /tmp/mongodb-mms-automation-agent-* /tmp/mongodb-agent.tar.gz 2>/dev/null || true
  "
  echo -e "  ${GREEN}✓ Agent binaries installed${NC}"
}

write_agent_config() {
  local container="$1"
  local group_id api_key

  group_id=$(docker exec node1 grep "^mmsGroupId=" /etc/mongodb-mms/automation-agent.config 2>/dev/null | cut -d= -f2)
  api_key=$(docker exec node1 grep "^mmsApiKey=" /etc/mongodb-mms/automation-agent.config 2>/dev/null | cut -d= -f2)

  if [ -z "$group_id" ] || [ -z "$api_key" ]; then
    echo -e "  ${RED}✗ Could not read Meta OM credentials from node1 container${NC}"
    exit 1
  fi

  docker exec -u root "$container" bash -c "cat > /etc/mongodb-mms/automation-agent.config << 'EOFCONFIG'
mmsGroupId=${group_id}
mmsApiKey=${api_key}
mmsBaseUrl=${META_OM_BASE_URL}
logFile=/var/log/mongodb-mms-automation/automation-agent.log
mmsConfigBackup=/var/lib/mongodb-mms-automation/mms-cluster-config-backup.json
logLevel=INFO
maxLogFiles=10
maxLogFileSize=268435456
EOFCONFIG"
  echo -e "  ${GREEN}✓ Agent config written (group: ${group_id:0:12}...)${NC}"
}

start_agent() {
  local container="$1"
  docker exec -u root "$container" bash -c "
    if pgrep -f mongodb-mms-automation-agent >/dev/null 2>&1; then
      pkill -f mongodb-mms-automation-agent 2>/dev/null || true
      sleep 2
      pkill -9 -f mongodb-mms-automation-agent 2>/dev/null || true
      sleep 1
    fi
    rm -f /tmp/mongodb-mms-automation.lock
    chown -R mongod:mongod /opt/mongodb-mms-automation /etc/mongodb-mms \
      /var/log/mongodb-mms-automation /var/lib/mongodb-mms-automation 2>/dev/null || true
  " || true

  docker exec -d -u mongod "$container" \
    /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent \
    -f /etc/mongodb-mms/automation-agent.config

  sleep 5

  if docker exec "$container" pgrep -f mongodb-mms-automation-agent >/dev/null 2>&1; then
    local agent_user
    agent_user=$(docker exec "$container" ps -o user= -p \
      "$(docker exec "$container" pgrep -f mongodb-mms-automation-agent | head -1)" 2>/dev/null | tr -d '[:space:]')
    echo -e "  ${GREEN}✓ Agent running (user: $agent_user)${NC}"
  else
    echo -e "  ${RED}✗ Agent failed to start${NC}"
    echo "    docker exec $container tail -20 /var/log/mongodb-mms-automation/automation-agent.log"
    exit 1
  fi
}

ensure_agent() {
  local container="$1"
  install_agent_binaries "$container"
  write_agent_config "$container"
  start_agent "$container"
}

# ── Per-instance provisioning ─────────────────────────────────────────────────

provision_instance() {
  local container="$1" host_port="$2" replica_set="$3" description="$4"
  local volume="${container}-data"
  local log_volume="${container}-log"

  echo ""
  echo -e "${BLUE}━━ $container — $description ━━${NC}"
  echo "  port: $host_port (same inside + outside)  |  RS: $replica_set"

  local already_healthy=false
  if [ "$FRESH" = false ] && [ "$REBUILD" = false ] && docker ps --filter "name=^${container}$" --filter "status=running" --format "{{.Names}}" | grep -q "$container"; then
    local rs_ok
    rs_ok=$(docker exec "$container" mongosh --port "$host_port" --quiet --eval \
      "try { print(rs.status().ok) } catch(e) { print(0) }" 2>/dev/null | tr -d '[:space:]')
    if [ "$rs_ok" = "1" ]; then
      already_healthy=true
    fi
  fi

  if [ "$already_healthy" = true ]; then
    echo -e "  ${GREEN}✓ Container already running and RS healthy${NC}"
  else
    if [ "$FRESH" = true ]; then
      docker stop "$container" 2>/dev/null || true
      docker rm "$container" 2>/dev/null || true
      docker volume rm "$volume" 2>/dev/null || true
      docker volume rm "$log_volume" 2>/dev/null || true
    elif [ "$REBUILD" = true ]; then
      echo "  --rebuild: stopping & removing container, preserving volume"
      docker stop "$container" 2>/dev/null || true
      docker rm "$container" 2>/dev/null || true
    elif docker volume inspect "$volume" &>/dev/null; then
      echo "  Existing volume found — restarting container without wiping data"
      docker stop "$container" 2>/dev/null || true
      docker rm "$container" 2>/dev/null || true
    else
      docker stop "$container" 2>/dev/null || true
      docker rm "$container" 2>/dev/null || true
    fi

    docker volume create "$volume" >/dev/null
    docker volume create "$log_volume" >/dev/null

    local conf_file
    conf_file=$(write_mongod_conf "$container" "$replica_set" "$host_port")

    # mongod log dir must be writable by the mongod user (UID 999 in this image)
    docker run --rm -u root \
      -v "${log_volume}":/var/log/mongodb \
      "$MONGODB_IMAGE" \
      bash -c "mkdir -p /var/log/mongodb && chown -R mongod:mongod /var/log/mongodb" 2>/dev/null || \
    docker run --rm -u root \
      -v "${log_volume}":/var/log/mongodb \
      alpine sh -c "mkdir -p /var/log/mongodb && chown -R 999:999 /var/log/mongodb"

    # Why this entrypoint setup:
    # --hostname  : stable agent registration name in Meta OM ("primary-om-appdb"
    #               etc.) so re-running reuses the same Server entry.
    # --init      : run docker's tini as PID 1 → reaps zombies left behind when
    #               the agent kills mongod for an automated restore.
    # --entrypoint: bootstrap script that starts mongod (forked, per
    #               processManagement.fork in the conf) and then becomes
    #               'tail -f /dev/null' to keep PID 2 alive even if mongod dies.
    #               Without this, mongod-as-PID-1 would mean "agent stops mongod"
    #               kills the container, breaking automated restores.
    docker run -d --init \
      --name "$container" \
      --hostname "$container" \
      --user 0:0 \
      -p "${host_port}":"${host_port}" \
      -v "${volume}":/data/db \
      -v "${log_volume}":/var/log/mongodb \
      -v "${conf_file}":/etc/mongodb/mongod.conf:ro \
      --entrypoint /bin/bash \
      "$MONGODB_IMAGE" \
      -c '
        chown -R mongod:mongod /data/db /var/log/mongodb 2>/dev/null || true
        # mongod.conf has fork:true so this returns once mongod is up.
        # runuser (not su) — su requires a password under PAM, runuser does not.
        runuser -u mongod -- /usr/bin/mongod --config /etc/mongodb/mongod.conf || \
          echo "WARNING: mongod failed to start at container boot — agent may start it later"
        exec tail -f /dev/null
      ' >/dev/null

    wait_for_mongod "$container" "$host_port"
  fi

  local container_ip
  container_ip=$(ensure_network "$container")
  if [ -z "$container_ip" ]; then
    echo -e "  ${RED}✗ Failed to attach to $DOCKER_NETWORK${NC}"
    exit 1
  fi
  echo -e "  ${GREEN}✓ Network $DOCKER_NETWORK — IP: $container_ip${NC}"

  # Initialize replica set if not already initialized.
  # Use the container's Docker DNS name (e.g. primary-om-appdb:27018) as the RS
  # member host. This resolves to a unique container IP from inside the docker
  # network — required so Meta OM's monitoring agent doesn't merge all backing
  # DBs into a single Server (which it would do if every member resolved to the
  # same IP, e.g. via host.docker.internal). Primary OM running on the macOS
  # host connects via host.docker.internal:<port> with directConnection=true,
  # so it never tries to follow this hostname.
  local rs_member_host="${container}:${host_port}"
  local rs_status
  rs_status=$(docker exec "$container" mongosh --port "$host_port" --quiet --eval \
    "try { print(rs.status().ok) } catch(e) { print(0) }" 2>/dev/null | tr -d '[:space:]')
  if [ "$rs_status" != "1" ]; then
    sleep 3
    local result
    result=$(docker exec "$container" mongosh --port "$host_port" --quiet --eval "
      try {
        const r = rs.initiate({_id: '$replica_set', members: [{_id: 0, host: '$rs_member_host'}]});
        print(JSON.stringify(r));
      } catch(e) {
        print(JSON.stringify({ok: 0, errmsg: e.message}));
      }" 2>&1)
    if echo "$result" | grep -q '"ok":1'; then
      echo -e "  ${GREEN}✓ Replica set initialized: $replica_set @ $rs_member_host${NC}"
    else
      echo -e "  ${RED}✗ rs.initiate failed: $result${NC}"
      exit 1
    fi
    sleep 3
  else
    ensure_rs_member_hostname "$container" "$host_port"
  fi

  ensure_agent "$container"

  echo -e "  ${GREEN}✓ $container ready — seed: host.docker.internal:${host_port}${NC}"
}

cleanup_legacy() {
  local found=false
  for c in "${LEGACY_CONTAINERS[@]}"; do
    if docker ps -a --filter "name=^${c}$" --format "{{.Names}}" | grep -q "$c"; then
      echo "  Removing legacy container: $c"
      docker stop "$c" 2>/dev/null || true
      docker rm "$c" 2>/dev/null || true
      found=true
    fi
  done
  for v in "${LEGACY_VOLUMES[@]}"; do
    if docker volume inspect "$v" &>/dev/null; then
      echo "  Removing legacy volume: $v"
      docker volume rm "$v" 2>/dev/null || true
      found=true
    fi
  done
  if [ "$found" = false ]; then
    echo "  No legacy artifacts to remove"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

echo "=== Primary OM Backing DBs Setup ==="
echo ""

# Verify prerequisites
if ! docker ps --filter "name=^ops$" --format "{{.Names}}" | grep -q "^ops$"; then
  echo -e "${RED}✗ Meta OM container 'ops' is not running${NC}"
  echo "  Start it with: cd om-docker && ./quick-start.sh"
  exit 1
fi
if ! docker ps --filter "name=^node1$" --format "{{.Names}}" | grep -q "^node1$"; then
  echo -e "${RED}✗ Meta OM agent container 'node1' is not running${NC}"
  echo "  Start it with: cd om-docker && ./quick-start.sh"
  exit 1
fi
echo -e "${GREEN}✓ Meta OM (ops + node1) is up${NC}"

mkdir -p "$CONFIG_DIR"

# Always remove legacy single-appdb container/volumes — they're superseded
echo ""
echo -e "${BLUE}Cleaning up legacy mongodb-ops-manager artifacts${NC}"
cleanup_legacy

if [ "$FRESH" = true ]; then
  echo ""
  echo -e "${YELLOW}⚠ --fresh: will wipe all backing-DB containers and volumes${NC}"
fi

# Provision each instance
for entry in "${INSTANCES[@]}"; do
  IFS='|' read -r container host_port replica_set description <<< "$entry"
  provision_instance "$container" "$host_port" "$replica_set" "$description"
done

echo ""
echo -e "${GREEN}=== All backing DBs ready ===${NC}"
echo ""
printf "%-26s %-10s %-16s %s\n" "CONTAINER" "HOST PORT" "REPLICA SET" "RS MEMBER HOST"
printf "%-26s %-10s %-16s %s\n" "─────────" "─────────" "───────────" "──────────────"
for entry in "${INSTANCES[@]}"; do
  IFS='|' read -r container host_port replica_set _ <<< "$entry"
  printf "%-26s %-10s %-16s %s\n" "$container" "$host_port" "$replica_set" "host.docker.internal:${host_port}"
done

echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. In Meta OM UI (http://localhost:8080) → each project → Add Existing Deployment"
echo "     Use the RS member hosts above (host.docker.internal:<port>)."
echo "  2. Configure Primary OM (conf-hosted.properties) to point appDB / S3 metadata /"
echo "     oplog metadata at the host ports above (27018 / 27019 / 27020)."
echo "  3. Once Meta OM is managing all three, enable backups for each in the UI."

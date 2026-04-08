#!/bin/bash

# Stop all local primary OM processes:
#   - Primary OM server (bazel run --server_env=hosted //server:mms)
#   - Local automation agent (go run cm.go --config=local.config)
#   - Local backup daemon (bazel run --server_env=hosted //server:daemon)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

kill_by_pattern() {
  local label="$1"
  local pattern="$2"
  local silent_if_absent="${3:-false}"
  local pids
  pids=$(pgrep -f "$pattern" 2>/dev/null)
  if [ -n "$pids" ]; then
    echo -e "${YELLOW}Stopping $label (PIDs: $pids)...${NC}"
    echo "$pids" | xargs kill -TERM 2>/dev/null
    sleep 10
    local survivors
    survivors=$(pgrep -f "$pattern" 2>/dev/null)
    if [ -n "$survivors" ]; then
      echo "$survivors" | xargs kill -9 2>/dev/null
      echo -e "${RED}✓ $label stopped (forcefully — SIGKILL)${NC}"
    else
      echo -e "${GREEN}✓ $label stopped (gracefully — SIGTERM)${NC}"
    fi
  elif [ "$silent_if_absent" = false ]; then
    echo "  $label — not running"
  fi
}

echo "=== Stopping local primary OM processes ==="
echo ""

# Match on unique flags — using single distinctive flag per process (macOS truncates long cmdlines)
kill_by_pattern "Primary OM server"      "Dapp-id=mms"
kill_by_pattern "Local backup daemon"    "Dapp-id=bgrid"
kill_by_pattern "Local automation agent" "cm\.go.*local\.config"
# Safety net: kill orphaned compiled binaries left by `go run`.
# Go compiles to paths like /tmp/go-buildXXX/exe/cm or ~/Library/Caches/go-build/.../cm
# and these can outlive the parent `go run` process, holding the lockfile.
kill_by_pattern "Local automation agent (orphaned binary)" "/cm --config=local\.config" true

# Remove stale lockfile left behind if the agent exited uncleanly
LOCKFILE="/tmp/mongodb-mms-automation.lock"
if [ -f "$LOCKFILE" ]; then
  rm -f "$LOCKFILE"
  echo -e "${GREEN}✓ Removed stale agent lockfile${NC}"
fi

echo ""
echo -e "${GREEN}=== Done ===${NC}"

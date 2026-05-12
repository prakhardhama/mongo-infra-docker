#!/bin/bash

# List snapshots across all four deployments — useful for capturing
# baselines before / after each restore-impact test.
#
# Usage:
#   ./list-snapshots.sh                   # plain text
#   ./list-snapshots.sh --md              # markdown table (paste into RESTORE-FINDINGS.md)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="$SCRIPT_DIR/KEYS.md"
META_OM_URL="${META_OM_URL:-http://localhost:8080}"
PRIMARY_OM_URL="${PRIMARY_OM_URL:-http://localhost:8081}"

MD=false
[ "$1" = "--md" ] && MD=true

get_key() {
  local section="$1" key="$2"
  awk -v section="## $section" -v key="$key=" '
    $0 == section { in_section = 1; next }
    /^##/ && in_section { in_section = 0 }
    in_section && index($0, key) == 1 {
      val = substr($0, length(key) + 1)
      gsub(/^"|"$/, "", val)
      print val
      exit
    }
  ' "$KEYS_FILE"
}

META_PUBLIC_KEY=$(get_key "META OM" "META_PUBLIC_KEY")
[ -z "$META_PUBLIC_KEY" ] && META_PUBLIC_KEY=$(get_key "META OM" "META_ADMIN_PUBLIC_KEY")
META_PRIVATE_KEY=$(get_key "META OM" "META_PRIVATE_KEY")
PRIMARY_PUBLIC_KEY=$(get_key "PRIMARY OM" "GLOBAL_PUBLIC_KEY")
PRIMARY_PRIVATE_KEY=$(get_key "PRIMARY OM" "GLOBAL_PRIVATE_KEY")

# Each entry: label|url|pub|priv|rs
TARGETS=(
  "Meta OM|${META_OM_URL}|${META_PUBLIC_KEY}|${META_PRIVATE_KEY}|appdb-rs"
  "Meta OM|${META_OM_URL}|${META_PUBLIC_KEY}|${META_PRIVATE_KEY}|s3-meta-rs"
  "Meta OM|${META_OM_URL}|${META_PUBLIC_KEY}|${META_PRIVATE_KEY}|oplog-meta-rs"
  "Primary OM|${PRIMARY_OM_URL}|${PRIMARY_PUBLIC_KEY}|${PRIMARY_PRIVATE_KEY}|poRepSet"
)

if $MD; then
  echo "_Captured at $(date -u +%Y-%m-%dT%H:%M:%SZ)_"
  echo ""
  echo "| OM | Replica Set | Created (UTC) | Size | Status | Snapshot ID |"
  echo "|---|---|---|---|---|---|"
else
  echo "=== Snapshot inventory @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
fi

for entry in "${TARGETS[@]}"; do
  IFS='|' read -r label url pub priv rs <<< "$entry"

  groups=$(curl -s --digest -u "${pub}:${priv}" "${url}/api/public/v1.0/groups")
  gid=$(echo "$groups" | python3 -c 'import sys,json
d=json.load(sys.stdin)
print(d["results"][0]["id"]) if d.get("results") else None' 2>/dev/null)
  if [ -z "$gid" ]; then
    if $MD; then
      echo "| $label | $rs | _no group / API failure_ |  |  |  |"
    else
      echo ""
      echo "── $label / $rs ──  (no group / API failure)"
    fi
    continue
  fi

  clusters=$(curl -s --digest -u "${pub}:${priv}" "${url}/api/public/v1.0/groups/${gid}/clusters")
  cid=$(echo "$clusters" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for c in d.get('results', []):
    if c.get('replicaSetName') == '${rs}':
        print(c['id']); break
" 2>/dev/null)

  if [ -z "$cid" ]; then
    if $MD; then
      echo "| $label | $rs | _not registered_ |  |  |  |"
    else
      echo ""
      echo "── $label / $rs ──  (not registered)"
    fi
    continue
  fi

  snaps=$(curl -s --digest -u "${pub}:${priv}" "${url}/api/public/v1.0/groups/${gid}/clusters/${cid}/snapshots?itemsPerPage=20")

  if $MD; then
    echo "$snaps" | LABEL="$label" RS="$rs" python3 -c "
import sys, json, os
label = os.environ['LABEL']; rs = os.environ['RS']
d = json.load(sys.stdin)
results = sorted(d.get('results', []), key=lambda s: s.get('created',{}).get('date',''))
if not results:
    print(f'| {label} | {rs} | _no snapshots_ |  |  |  |')
for s in results:
    created = s.get('created',{}).get('date','?')
    parts = s.get('parts', [])
    size = parts[0].get('dataSizeBytes', 0) if parts else 0
    size_str = f'{size/1024/1024:.1f}MB' if size > 0 else '0MB'
    status = 'complete' if s.get('complete') else 'incomplete'
    sid = s.get('id','')[:8]
    print(f'| {label} | {rs} | {created} | {size_str} | {status} | {sid}… |')
" 2>/dev/null
  else
    echo ""
    echo "── $label / $rs ──"
    echo "$snaps" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = sorted(d.get('results', []), key=lambda s: s.get('created',{}).get('date',''))
print(f'  total: {d.get(\"totalCount\",0)}')
for s in results:
    created = s.get('created',{}).get('date','?')
    expires = s.get('expires','?')
    complete = '✓' if s.get('complete') else '✗'
    parts = s.get('parts', [])
    size = parts[0].get('dataSizeBytes', 0) if parts else 0
    size_str = f'{size/1024/1024:.1f}MB' if size > 0 else '0MB'
    print(f'  {complete} {created}  size={size_str:>9}  id={s.get(\"id\",\"\")[:8]}…  expires={expires}')
" 2>/dev/null
  fi
done

#!/usr/bin/env bash
# Runs INSIDE the one-shot bootstrap container. Wires all services together.
# Every step is idempotent: check current state, only create what's missing.
set -euo pipefail

QB=http://qbittorrent:8080
PROWLARR=http://prowlarr:9696
RADARR=http://radarr:7878
SONARR=http://sonarr:8989
JF=http://jellyfin:8096
JS=http://jellyseerr:5055

log()  { printf '>> %s\n' "$*"; }
fail() { printf '!! ERROR: %s\n' "$*" >&2; exit 1; }

# wait_for <name> <url> [timeout-seconds]
wait_for() {
  local name=$1 url=$2 timeout=${3:-180} start
  start=$(date +%s)
  until curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
    if (( $(date +%s) - start > timeout )); then
      fail "$name did not become healthy after ${timeout}s — check: docker logs $name"
    fi
    sleep 3
  done
  log "$name is up"
}

# arr_api <base-url> <api-key> <METHOD> <path> [json-body]
arr_api() {
  local base=$1 key=$2 method=$3 path=$4 body=${5:-}
  curl -fsS -X "$method" \
    -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
    ${body:+--data "$body"} \
    "${base}${path}"
}

# ensure <description> <check-cmd...> -- <create-cmd...>
# Runs check; if it fails, runs create. Both are full commands.
ensure() {
  local desc=$1; shift
  local check=() create=() seen_sep=0 arg
  for arg in "$@"; do
    if [[ $arg == -- && $seen_sep == 0 ]]; then seen_sep=1; continue; fi
    if [[ $seen_sep == 0 ]]; then check+=("$arg"); else create+=("$arg"); fi
  done
  if "${check[@]}" >/dev/null 2>&1; then
    log "$desc — already configured, skipping"
  else
    "${create[@]}" >/dev/null
    log "$desc — created"
  fi
}

# ---------------------------------------------------------------- qBittorrent
log "=== qBittorrent ==="
wait_for qbittorrent "$QB/api/v2/app/version"

# Set a known WebUI password (subnet whitelist lets us call without auth).
curl -fsS -X POST "$QB/api/v2/app/setPreferences" \
  --data-urlencode "json={\"web_ui_username\":\"${QBIT_USER}\",\"web_ui_password\":\"${QBIT_PASSWORD}\"}" \
  >/dev/null
log "qBittorrent WebUI credentials set"

qb_has_category() {
  curl -fsS "$QB/api/v2/torrents/categories" | jq -e --arg c "$1" 'has($c)'
}
qb_add_category() {
  curl -fsS -X POST "$QB/api/v2/torrents/createCategory" \
    --data-urlencode "category=$1" --data-urlencode "savePath=$2"
}
ensure "qBittorrent category 'movies'" \
  qb_has_category movies -- qb_add_category movies /data/torrents/movies
ensure "qBittorrent category 'tv'" \
  qb_has_category tv     -- qb_add_category tv     /data/torrents/tv

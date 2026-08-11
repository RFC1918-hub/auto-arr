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

# ------------------------------------------------------------- arr common
# arr_set_auth <base> <key> <api-ver>  — set forms login on first run
arr_set_auth() {
  local base=$1 key=$2 ver=$3 host
  host=$(arr_api "$base" "$key" GET "/api/${ver}/config/host")
  if echo "$host" | jq -e --arg u "$ARR_ADMIN_USER" '.username == $u' >/dev/null; then
    log "auth — already configured, skipping"
    return 0
  fi
  arr_api "$base" "$key" PUT "/api/${ver}/config/host" \
    "$(echo "$host" | jq --arg u "$ARR_ADMIN_USER" --arg p "$ARR_ADMIN_PASSWORD" \
        '.authenticationMethod = "forms"
         | .authenticationRequired = "enabled"
         | .username = $u | .password = $p | .passwordConfirmation = $p')" \
    >/dev/null
  log "auth — forms login configured"
}

# arr_has_rootfolder <base> <key> <api-ver> <path>
arr_has_rootfolder() {
  arr_api "$1" "$2" GET "/api/$3/rootfolder" \
    | jq -e --arg p "$4" '.[] | select(.path == $p)'
}
# arr_add_rootfolder <base> <key> <api-ver> <path>
arr_add_rootfolder() {
  arr_api "$1" "$2" POST "/api/$3/rootfolder" "{\"path\":\"$4\"}"
}

# arr_has_downloadclient <base> <key> <api-ver>
arr_has_downloadclient() {
  arr_api "$1" "$2" GET "/api/$3/downloadclient" \
    | jq -e '.[] | select(.name == "qBittorrent")'
}
# arr_add_downloadclient <base> <key> <api-ver> <category-field> <category>
arr_add_downloadclient() {
  arr_api "$1" "$2" POST "/api/$3/downloadclient" "$(jq -n \
    --arg catfield "$4" --arg cat "$5" \
    --arg user "$QBIT_USER" --arg pass "$QBIT_PASSWORD" \
    '{
      enable: true, protocol: "torrent", priority: 1,
      name: "qBittorrent", implementation: "QBittorrent",
      implementationName: "qBittorrent", configContract: "QBittorrentSettings",
      fields: [
        {name: "host", value: "qbittorrent"},
        {name: "port", value: 8080},
        {name: "useSsl", value: false},
        {name: "username", value: $user},
        {name: "password", value: $pass},
        {name: $catfield, value: $cat}
      ]
    }')"
}

# ---------------------------------------------------------------- Radarr
log "=== Radarr ==="
wait_for radarr "$RADARR/api/v3/system/status?apikey=${RADARR_API_KEY}"
arr_set_auth "$RADARR" "$RADARR_API_KEY" v3
ensure "Radarr root folder /data/media/movies" \
  arr_has_rootfolder "$RADARR" "$RADARR_API_KEY" v3 /data/media/movies -- \
  arr_add_rootfolder "$RADARR" "$RADARR_API_KEY" v3 /data/media/movies
ensure "Radarr download client qBittorrent" \
  arr_has_downloadclient "$RADARR" "$RADARR_API_KEY" v3 -- \
  arr_add_downloadclient "$RADARR" "$RADARR_API_KEY" v3 movieCategory movies

# ---------------------------------------------------------------- Sonarr
log "=== Sonarr ==="
wait_for sonarr "$SONARR/api/v3/system/status?apikey=${SONARR_API_KEY}"
arr_set_auth "$SONARR" "$SONARR_API_KEY" v3
ensure "Sonarr root folder /data/media/tv" \
  arr_has_rootfolder "$SONARR" "$SONARR_API_KEY" v3 /data/media/tv -- \
  arr_add_rootfolder "$SONARR" "$SONARR_API_KEY" v3 /data/media/tv
ensure "Sonarr download client qBittorrent" \
  arr_has_downloadclient "$SONARR" "$SONARR_API_KEY" v3 -- \
  arr_add_downloadclient "$SONARR" "$SONARR_API_KEY" v3 tvCategory tv

# ---------------------------------------------------------------- Prowlarr
log "=== Prowlarr ==="
wait_for prowlarr "$PROWLARR/api/v1/system/status?apikey=${PROWLARR_API_KEY}"
arr_set_auth "$PROWLARR" "$PROWLARR_API_KEY" v1

# prowlarr_has_app <name> / prowlarr_add_app <name> <base-url> <api-key>
prowlarr_has_app() {
  arr_api "$PROWLARR" "$PROWLARR_API_KEY" GET /api/v1/applications \
    | jq -e --arg n "$1" '.[] | select(.name == $n)'
}
prowlarr_add_app() {
  arr_api "$PROWLARR" "$PROWLARR_API_KEY" POST /api/v1/applications "$(jq -n \
    --arg name "$1" --arg base "$2" --arg key "$3" \
    '{
      name: $name, implementation: $name, implementationName: $name,
      configContract: ($name + "Settings"), syncLevel: "fullSync",
      fields: [
        {name: "prowlarrUrl", value: "http://prowlarr:9696"},
        {name: "baseUrl", value: $base},
        {name: "apiKey", value: $key}
      ]
    }')"
}
ensure "Prowlarr application Radarr" \
  prowlarr_has_app Radarr -- prowlarr_add_app Radarr "$RADARR" "$RADARR_API_KEY"
ensure "Prowlarr application Sonarr" \
  prowlarr_has_app Sonarr -- prowlarr_add_app Sonarr "$SONARR" "$SONARR_API_KEY"

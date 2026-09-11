#!/usr/bin/env bash
# Runs INSIDE the one-shot bootstrap container. Wires all services together.
# Every step is idempotent: check current state, only create what's missing.
# shellcheck disable=SC2329  # check/create helpers are invoked indirectly via ensure()
set -euo pipefail

QB=http://qbittorrent:8080
PROWLARR=http://prowlarr:9696
RADARR=http://radarr:7878
SONARR=http://sonarr:8989
JF=http://jellyfin:8096
JS=http://jellyseerr:5055
FLARESOLVERR=http://flaresolverr:8191

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

# Download paths: keep downloads under /data/torrents and use Automatic Torrent
# Management so each category's save path (/data/torrents/<category>) applies.
# In the default Manual mode qBittorrent ignores category paths and saves to its
# private /config/Downloads, which Radarr/Sonarr cannot see, so nothing imports.
curl -fsS -X POST "$QB/api/v2/app/setPreferences" \
  --data-urlencode 'json={"save_path":"/data/torrents","auto_tmm_enabled":true,"torrent_changed_tmm_enabled":true,"save_path_changed_tmm_enabled":true,"category_changed_tmm_enabled":true}' \
  >/dev/null
log "qBittorrent save path /data/torrents, automatic torrent management on"

# Seeding cleanup: pause a torrent once either share limit is reached (0 = no
# limit). Radarr/Sonarr then remove paused-complete torrents with their files
# once imported (see arr_set_remove_completed). Pausing instead of deleting here
# guarantees the files still exist when the app imports them; library files are
# hardlinks, so they are never affected.
SEED_RATIO=${SEED_RATIO:-1.0}
SEED_TIME_MINUTES=${SEED_TIME_MINUTES:-1440}
curl -fsS -X POST "$QB/api/v2/app/setPreferences" \
  --data-urlencode "json=$(jq -n --argjson r "$SEED_RATIO" --argjson t "$SEED_TIME_MINUTES" '
    {max_ratio_act: 0}
    + (if $r > 0 then {max_ratio_enabled: true, max_ratio: $r} else {max_ratio_enabled: false} end)
    + (if $t > 0 then {max_seeding_time_enabled: true, max_seeding_time: $t} else {max_seeding_time_enabled: false} end)')" \
  >/dev/null
log "qBittorrent seeding limits: ratio ${SEED_RATIO}, ${SEED_TIME_MINUTES} min (0 = off) — pause when reached"

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

# Torrents added while management was Manual sit in /config/Downloads. Switching
# them to Automatic makes qBittorrent relocate them into their category path, after
# which the apps' pending imports complete on their next check.
qb_manual=$(curl -fsS "$QB/api/v2/torrents/info" \
  | jq -c '[.[] | select((.category == "movies" or .category == "tv") and .auto_tmm == false) | .hash]')
if [[ "$qb_manual" != "[]" ]]; then
  curl -fsS -X POST "$QB/api/v2/torrents/setAutoManagement" \
    --data-urlencode "hashes=$(jq -r 'join("|")' <<<"$qb_manual")" --data-urlencode "enable=true" >/dev/null
  log "qBittorrent: $(jq length <<<"$qb_manual") existing torrent(s) switched to automatic management — relocating to /data/torrents/<category>"
else
  log "qBittorrent torrents — all under automatic management, skipping"
fi

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
      removeCompletedDownloads: true, removeFailedDownloads: true,
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

# arr_set_remove_completed <base> <key> <api-ver> — make the app delete its
# torrents (and their files) from qBittorrent once imported and done seeding.
# Fixes installs whose client was created before this option was set.
arr_set_remove_completed() {
  local base=$1 key=$2 ver=$3 client
  client=$(arr_api "$base" "$key" GET "/api/${ver}/downloadclient" \
    | jq -c '.[] | select(.name == "qBittorrent")')
  [[ -n "$client" ]] || fail "qBittorrent download client not found at ${base}"
  if jq -e '.removeCompletedDownloads == true and .removeFailedDownloads == true' <<<"$client" >/dev/null; then
    log "download client cleanup — already configured, skipping"
    return 0
  fi
  arr_api "$base" "$key" PUT "/api/${ver}/downloadclient/$(jq -r '.id' <<<"$client")" \
    "$(jq '.removeCompletedDownloads = true | .removeFailedDownloads = true' <<<"$client")" >/dev/null
  log "download client cleanup — remove completed/failed downloads enabled"
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
arr_set_remove_completed "$RADARR" "$RADARR_API_KEY" v3

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
arr_set_remove_completed "$SONARR" "$SONARR_API_KEY" v3

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

# ---------------------------------------------------------------- FlareSolverr
# Prowlarr routes an indexer through an indexer proxy only when the two share a
# tag, so create the 'flaresolverr' tag and attach it to the proxy. Users add
# that tag to Cloudflare-protected indexers (e.g. 1337x) when adding them.
wait_for flaresolverr "$FLARESOLVERR/"

# prowlarr_tag_id <label> — prints the tag's id, creating the tag if needed
prowlarr_tag_id() {
  local id
  id=$(arr_api "$PROWLARR" "$PROWLARR_API_KEY" GET /api/v1/tag \
    | jq -r --arg l "$1" '.[] | select(.label == $l) | .id')
  if [[ -z "$id" ]]; then
    id=$(arr_api "$PROWLARR" "$PROWLARR_API_KEY" POST /api/v1/tag \
      "$(jq -n --arg l "$1" '{label: $l}')" | jq -r '.id')
  fi
  echo "$id"
}
prowlarr_has_proxy() {
  arr_api "$PROWLARR" "$PROWLARR_API_KEY" GET /api/v1/indexerproxy \
    | jq -e '.[] | select(.name == "FlareSolverr")'
}
prowlarr_add_proxy() {
  local tag
  tag=$(prowlarr_tag_id flaresolverr)
  arr_api "$PROWLARR" "$PROWLARR_API_KEY" POST /api/v1/indexerproxy "$(jq -n \
    --argjson tag "$tag" --arg host "$FLARESOLVERR/" \
    '{
      name: "FlareSolverr", implementation: "FlareSolverr",
      implementationName: "FlareSolverr", configContract: "FlareSolverrSettings",
      fields: [
        {name: "host", value: $host},
        {name: "requestTimeout", value: 60}
      ],
      tags: [$tag]
    }')"
}
ensure "Prowlarr indexer proxy FlareSolverr (tag 'flaresolverr')" \
  prowlarr_has_proxy -- prowlarr_add_proxy

# ---------------------------------------------------------------- Jellyfin
log "=== Jellyfin ==="
# Jellyfin 12+ serves a startup/migration placeholder that answers /health (and
# some GETs) with 200 while the real API still returns 503 HTML. Wait until
# /System/Info/Public returns actual JSON, which only the real server does.
jf_ready() { curl -fsS --max-time 5 "$JF/System/Info/Public" 2>/dev/null | jq -e '.Version' >/dev/null 2>&1; }
jf_start=$(date +%s)
until jf_ready; do
  if (( $(date +%s) - jf_start > 300 )); then
    fail "jellyfin did not become ready after 300s — check: docker logs jellyfin"
  fi
  sleep 3
done
log "jellyfin is up"

JF_AUTH='Authorization: MediaBrowser Client="auto-arr", Device="bootstrap", DeviceId="auto-arr-bootstrap", Version="1.0"'

jf_wizard_done() {
  curl -fsS "$JF/System/Info/Public" | jq -e '.StartupWizardCompleted == true'
}

if jf_wizard_done >/dev/null 2>&1; then
  log "startup wizard — already completed, skipping"
else
  curl -fsS -X POST "$JF/Startup/Configuration" -H "$JF_AUTH" \
    -H 'Content-Type: application/json' \
    -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}'
  # GET before POST is required by the wizard flow
  curl -fsS "$JF/Startup/User" -H "$JF_AUTH" >/dev/null
  curl -fsS -X POST "$JF/Startup/User" -H "$JF_AUTH" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$JELLYFIN_ADMIN_USER" --arg p "$JELLYFIN_ADMIN_PASSWORD" \
          '{Name: $u, Password: $p}')"
  curl -fsS -X POST "$JF/Startup/RemoteAccess" -H "$JF_AUTH" \
    -H 'Content-Type: application/json' \
    -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'
  curl -fsS -X POST "$JF/Startup/Complete" -H "$JF_AUTH"
  log "startup wizard — completed"
fi

# Jellyfin 12 can briefly refuse/deny requests while it settles right after
# Startup/Complete (port rebind + post-wizard reconfiguration), so retry.
JF_TOKEN=""
for _ in {1..20}; do
  JF_TOKEN=$(curl -fsS -X POST "$JF/Users/AuthenticateByName" \
    -H "$JF_AUTH" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$JELLYFIN_ADMIN_USER" --arg p "$JELLYFIN_ADMIN_PASSWORD" \
          '{Username: $u, Pw: $p}')" 2>/dev/null | jq -r '.AccessToken // empty' || true)
  [[ -n "$JF_TOKEN" ]] && break
  sleep 3
done
[[ -n "$JF_TOKEN" ]] || fail "could not authenticate to Jellyfin as ${JELLYFIN_ADMIN_USER} — if this is Jellyfin 12+, check EnableLegacyAuthorization in config/jellyfin/system.xml"

# Jellyfin 12 ships fresh installs with EnableLegacyAuthorization=false, which
# rejects the X-Emby-Token header (401). Present the token in the supported
# 'Authorization: MediaBrowser ..., Token=' form (works on 10.x too).
JF_TOK_AUTH="Authorization: MediaBrowser Client=\"auto-arr\", Device=\"bootstrap\", DeviceId=\"auto-arr-bootstrap\", Version=\"1.0\", Token=\"$JF_TOKEN\""

jf_has_library() {
  curl -fsS -H "$JF_TOK_AUTH" "$JF/Library/VirtualFolders" \
    | jq -e --arg n "$1" '.[] | select(.Name == $n)'
}
# jf_add_library <name> <collectionType> <url-encoded-path>
jf_add_library() {
  curl -fsS -X POST -H "$JF_TOK_AUTH" -H 'Content-Type: application/json' \
    -d '{"LibraryOptions":{"EnableRealtimeMonitor":true}}' \
    "$JF/Library/VirtualFolders?name=$1&collectionType=$2&paths=$3&refreshLibrary=true"
}
ensure "Jellyfin library Movies" \
  jf_has_library Movies -- jf_add_library Movies movies  %2Fdata%2Fmedia%2Fmovies
ensure "Jellyfin library Shows" \
  jf_has_library Shows  -- jf_add_library Shows  tvshows %2Fdata%2Fmedia%2Ftv

curl -fsS -X POST -H "$JF_TOK_AUTH" "$JF/Library/Refresh"
log "library scan triggered"

# API key the arr apps use to tell Jellyfin about imports (reused if present).
jf_api_key() {
  local key
  key=$(curl -fsS -H "$JF_TOK_AUTH" "$JF/Auth/Keys" \
    | jq -r '.Items[] | select(.AppName == "auto-arr") | .AccessToken' | head -n1)
  if [[ -z "$key" ]]; then
    curl -fsS -X POST -H "$JF_TOK_AUTH" "$JF/Auth/Keys?app=auto-arr" >/dev/null
    key=$(curl -fsS -H "$JF_TOK_AUTH" "$JF/Auth/Keys" \
      | jq -r '.Items[] | select(.AppName == "auto-arr") | .AccessToken' | head -n1)
  fi
  [[ -n "$key" ]] || fail "could not create a Jellyfin API key for the arr apps"
  echo "$key"
}
JF_API_KEY=$(jf_api_key)
log "Jellyfin API key for Radarr/Sonarr — ready"

# ------------------------------------------- Radarr/Sonarr → Jellyfin refresh
# Have each app tell Jellyfin to update its library the moment it imports,
# upgrades, renames or deletes media. Jellyfin's real-time folder watching is
# unreliable in Docker and its scheduled scan is hours apart, so without this
# new media only appears after the next scan.
arr_has_jellyfin_connect() {
  arr_api "$1" "$2" GET "/api/$3/notification" | jq -e '.[] | select(.name == "Jellyfin")'
}
# arr_add_jellyfin_connect <base> <key> <api-ver> <event-flags-json>
arr_add_jellyfin_connect() {
  arr_api "$1" "$2" POST "/api/$3/notification" "$(arr_api "$1" "$2" GET "/api/$3/notification/schema" \
    | jq --arg k "$JF_API_KEY" --argjson ev "$4" '
      [.[] | select(.implementation == "MediaBrowser")][0]
      | .name = "Jellyfin" | .tags = []
      | .fields |= map(
          if   .name == "host"          then .value = "jellyfin"
          elif .name == "port"          then .value = 8096
          elif .name == "useSsl"        then .value = false
          elif .name == "apiKey"        then .value = $k
          elif .name == "notify"        then .value = false
          elif .name == "updateLibrary" then .value = true
          else . end)
      | . + $ev')"
}
RADARR_JF_EVENTS='{"onDownload":true,"onUpgrade":true,"onRename":true,"onMovieDelete":true,"onMovieFileDelete":true,"onMovieFileDeleteForUpgrade":true}'
SONARR_JF_EVENTS='{"onDownload":true,"onUpgrade":true,"onImportComplete":true,"onRename":true,"onSeriesDelete":true,"onEpisodeFileDelete":true,"onEpisodeFileDeleteForUpgrade":true}'
ensure "Radarr → Jellyfin library refresh on import" \
  arr_has_jellyfin_connect "$RADARR" "$RADARR_API_KEY" v3 -- \
  arr_add_jellyfin_connect "$RADARR" "$RADARR_API_KEY" v3 "$RADARR_JF_EVENTS"
ensure "Sonarr → Jellyfin library refresh on import" \
  arr_has_jellyfin_connect "$SONARR" "$SONARR_API_KEY" v3 -- \
  arr_add_jellyfin_connect "$SONARR" "$SONARR_API_KEY" v3 "$SONARR_JF_EVENTS"

# ---------------------------------------------------------------- Jellyseerr
log "=== Jellyseerr ==="
wait_for jellyseerr "$JS/api/v1/status"

JS_COOKIES=/tmp/jellyseerr.cookies
js_initialized() {
  curl -fsS "$JS/api/v1/settings/public" | jq -e '.initialized == true'
}
js_login() {
  # Once an admin exists, a plain login works (sending hostname again is a 500).
  if curl -fsS -c "$JS_COOKIES" -X POST "$JS/api/v1/auth/jellyfin" \
       -H 'Content-Type: application/json' \
       -d "$(jq -n --arg u "$JELLYFIN_ADMIN_USER" --arg p "$JELLYFIN_ADMIN_PASSWORD" \
             '{username: $u, password: $p}')" >/dev/null 2>&1; then
    return 0
  fi
  # First run: full setup body — connects Jellyfin and creates the admin user.
  # serverType 2 = MediaServerType.JELLYFIN (required since Jellyseerr 2.x).
  curl -fsS -c "$JS_COOKIES" -X POST "$JS/api/v1/auth/jellyfin" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$JELLYFIN_ADMIN_USER" --arg p "$JELLYFIN_ADMIN_PASSWORD" \
          '{username: $u, password: $p, hostname: "jellyfin", port: 8096,
            useSsl: false, urlBase: "", email: "admin@auto-arr.local",
            serverType: 2}')"
}
js_api() { # <METHOD> <path> [json-body]
  local method=$1 path=$2 body=${3:-}
  curl -fsS -b "$JS_COOKIES" -X "$method" -H 'Content-Type: application/json' \
    ${body:+--data "$body"} "${JS}${path}"
}

js_login >/dev/null
log "authenticated to Jellyseerr via Jellyfin account"

# enable all synced Jellyfin libraries
LIB_IDS=$(js_api GET "/api/v1/settings/jellyfin/library?sync=true" | jq -r 'map(.id) | join(",")')
[[ -n "$LIB_IDS" ]] && js_api GET "/api/v1/settings/jellyfin/library?enable=${LIB_IDS}" >/dev/null
log "Jellyseerr libraries enabled: ${LIB_IDS:-none}"

js_has_radarr() { js_api GET /api/v1/settings/radarr | jq -e 'length > 0'; }
js_add_radarr() {
  local profile_id profile_name
  profile_id=$(arr_api "$RADARR" "$RADARR_API_KEY" GET /api/v3/qualityprofile | jq '.[0].id')
  profile_name=$(arr_api "$RADARR" "$RADARR_API_KEY" GET /api/v3/qualityprofile | jq -r '.[0].name')
  js_api POST /api/v1/settings/radarr "$(jq -n \
    --arg key "$RADARR_API_KEY" --argjson pid "$profile_id" --arg pname "$profile_name" \
    '{name: "Radarr", hostname: "radarr", port: 7878, apiKey: $key, useSsl: false,
      baseUrl: "", activeProfileId: $pid, activeProfileName: $pname,
      activeDirectory: "/data/media/movies", is4k: false, isDefault: true,
      minimumAvailability: "released", syncEnabled: true, preventSearch: false,
      tags: []}')"
}
ensure "Jellyseerr Radarr server" js_has_radarr -- js_add_radarr

js_has_sonarr() { js_api GET /api/v1/settings/sonarr | jq -e 'length > 0'; }
js_add_sonarr() {
  local profile_id profile_name
  profile_id=$(arr_api "$SONARR" "$SONARR_API_KEY" GET /api/v3/qualityprofile | jq '.[0].id')
  profile_name=$(arr_api "$SONARR" "$SONARR_API_KEY" GET /api/v3/qualityprofile | jq -r '.[0].name')
  js_api POST /api/v1/settings/sonarr "$(jq -n \
    --arg key "$SONARR_API_KEY" --argjson pid "$profile_id" --arg pname "$profile_name" \
    '{name: "Sonarr", hostname: "sonarr", port: 8989, apiKey: $key, useSsl: false,
      baseUrl: "", activeProfileId: $pid, activeProfileName: $pname,
      activeDirectory: "/data/media/tv", activeAnimeDirectory: "",
      is4k: false, isDefault: true, syncEnabled: true, preventSearch: false,
      enableSeasonFolders: true, tags: [], animeTags: []}')"
}
ensure "Jellyseerr Sonarr server" js_has_sonarr -- js_add_sonarr

if ! js_initialized >/dev/null 2>&1; then
  js_api POST /api/v1/settings/initialize >/dev/null
  log "Jellyseerr marked initialized"
fi

# ---------------------------------------------------------------- summary
log "=== all services wired ==="
log "qBittorrent: password set, downloads under /data/torrents, categories movies/tv, seeding limits ratio ${SEED_RATIO} / ${SEED_TIME_MINUTES} min"
log "Radarr/Sonarr: root folders + qBittorrent download client (finished torrents removed after import)"
log "Prowlarr: Radarr + Sonarr applications (full sync), FlareSolverr proxy for indexers tagged 'flaresolverr'"
log "Jellyfin: admin user, Movies + Shows libraries, scan triggered, refreshed by Radarr/Sonarr on import"
log "Jellyseerr: connected to Jellyfin, Radarr and Sonarr"
exit 0

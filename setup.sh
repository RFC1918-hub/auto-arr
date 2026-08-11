#!/usr/bin/env bash
# auto-arr: one-command arr-stack installer. Run: ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\033[1;32m[auto-arr]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[auto-arr] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# ---------- preflight ----------
command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine first: https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1     || die "docker daemon not reachable (is it running? do you need to be in the docker group?)"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found. Install docker-compose-plugin."

# port_free <port> — true if nothing is listening (bash /dev/tcp probe; no extra tools)
port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---------- .env generation (first run only) ----------
if [[ ! -f .env ]]; then
  say "Generating .env with fresh secrets"
  for port in 8080 9696 7878 8989 8096 5055; do
    port_free "$port" || die "port $port is already in use — free it or edit the *_PORT values in .env.example before first run"
  done
  cp .env.example .env
  TZ_DETECTED=$( { cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null; } | head -n1 )
  [[ -n "${TZ_DETECTED:-}" ]] && sed -i "s|^TZ=.*|TZ=${TZ_DETECTED}|" .env
  sed -i "s|^PUID=.*|PUID=$(id -u)|; s|^PGID=.*|PGID=$(id -g)|" .env
  sed -i "s|^RADARR_API_KEY=.*|RADARR_API_KEY=$(rand_hex 16)|" .env
  sed -i "s|^SONARR_API_KEY=.*|SONARR_API_KEY=$(rand_hex 16)|" .env
  sed -i "s|^PROWLARR_API_KEY=.*|PROWLARR_API_KEY=$(rand_hex 16)|" .env
  sed -i "s|^ARR_ADMIN_PASSWORD=.*|ARR_ADMIN_PASSWORD=$(rand_hex 12)|" .env
  sed -i "s|^QBIT_PASSWORD=.*|QBIT_PASSWORD=$(rand_hex 12)|" .env
  sed -i "s|^JELLYFIN_ADMIN_PASSWORD=.*|JELLYFIN_ADMIN_PASSWORD=$(rand_hex 12)|" .env
else
  say "Existing .env found — keeping it (delete .env to regenerate)"
fi

# shellcheck disable=SC1091  # generated above
set -a; source .env; set +a

# ---------- credentials file ----------
{
  echo "auto-arr credentials — keep this file private (git-ignored)"
  echo
  echo "Radarr/Sonarr/Prowlarr login: ${ARR_ADMIN_USER} / ${ARR_ADMIN_PASSWORD}"
  echo "qBittorrent login:            ${QBIT_USER} / ${QBIT_PASSWORD}"
  echo "Jellyfin/Jellyseerr login:    ${JELLYFIN_ADMIN_USER} / ${JELLYFIN_ADMIN_PASSWORD}"
  echo
  echo "Radarr API key:   ${RADARR_API_KEY}"
  echo "Sonarr API key:   ${SONARR_API_KEY}"
  echo "Prowlarr API key: ${PROWLARR_API_KEY}"
} > credentials.txt
chmod 600 credentials.txt

# ---------- folders ----------
say "Creating folder tree under ${DATA_ROOT} and ${CONFIG_ROOT}"
mkdir -p \
  "${DATA_ROOT}/torrents/movies" "${DATA_ROOT}/torrents/tv" \
  "${DATA_ROOT}/media/movies"    "${DATA_ROOT}/media/tv" \
  "${CONFIG_ROOT}/qbittorrent"   "${CONFIG_ROOT}/prowlarr" \
  "${CONFIG_ROOT}/radarr"        "${CONFIG_ROOT}/sonarr" \
  "${CONFIG_ROOT}/jellyfin"      "${CONFIG_ROOT}/jellyseerr"

# ---------- qBittorrent pre-seed ----------
# Whitelist the compose subnet so bootstrap (and Radarr/Sonarr) can use the
# API before a password exists. LAN users still get a login page.
QBIT_CONF="${CONFIG_ROOT}/qbittorrent/qBittorrent/qBittorrent.conf"
if [[ ! -f "$QBIT_CONF" ]]; then
  say "Pre-seeding qBittorrent config"
  mkdir -p "$(dirname "$QBIT_CONF")"
  cat > "$QBIT_CONF" <<'EOF'
[LegalNotice]
Accepted=true

[Preferences]
WebUI\Username=admin
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\AuthSubnetWhitelist=172.28.0.0/16
EOF
fi

# ---------- launch ----------
say "Starting stack (first run pulls images — may take a few minutes)"
docker compose up -d

say "Waiting for bootstrap to wire everything together…"
docker logs -f arr-bootstrap 2>&1 | sed 's/^/  /' &
LOGS_PID=$!
BOOT_EXIT=$(docker wait arr-bootstrap)
kill "$LOGS_PID" 2>/dev/null || true
wait "$LOGS_PID" 2>/dev/null || true

[[ "$BOOT_EXIT" == "0" ]] || die "bootstrap failed (exit $BOOT_EXIT). Inspect: docker logs arr-bootstrap — then re-run ./setup.sh to resume."

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
HOST_IP=${HOST_IP:-localhost}
say "All wired up. Services:"
cat <<EOF
  Jellyfin    http://${HOST_IP}:${JELLYFIN_PORT}
  Jellyseerr  http://${HOST_IP}:${JELLYSEERR_PORT}
  Radarr      http://${HOST_IP}:${RADARR_PORT}
  Sonarr      http://${HOST_IP}:${SONARR_PORT}
  Prowlarr    http://${HOST_IP}:${PROWLARR_PORT}
  qBittorrent http://${HOST_IP}:${QBIT_PORT}

  Logins: see ./credentials.txt
  Next step: open Prowlarr and add your indexers — they sync to Radarr/Sonarr automatically.
EOF

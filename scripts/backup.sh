#!/usr/bin/env bash
# Backs up everything that is state: config/ (every app's database and settings),
# .env and credentials.txt. Media under data/ is not included. Keeps the newest
# BACKUP_KEEP archives (default 7). Caches, logs, transcodes and cover images are
# skipped; the apps regenerate them.
#
# Nightly via cron:  30 4 * * * /opt/auto-arr/scripts/backup.sh >>/var/log/auto-arr-backup.log 2>&1
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1091
source .env
set +a

DEST=${BACKUP_DIR:-./backups}
KEEP=${BACKUP_KEEP:-7}
mkdir -p "$DEST"

stamp=$(date +%Y%m%d-%H%M%S)
archive="$DEST/auto-arr-$stamp.tar.gz"
items=(.env "$CONFIG_ROOT")
[[ -f credentials.txt ]] && items+=(credentials.txt)

tar --create --gzip --file "$archive" \
  --exclude=cache --exclude=log --exclude=logs --exclude=transcodes --exclude=MediaCover \
  --warning=no-file-changed \
  "${items[@]}"
chmod 600 "$archive"

# rotate: keep the newest $KEEP
ls -1t "$DEST"/auto-arr-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm -f

printf '%s backup written: %s (%s), keeping %s\n' "$(date '+%F %T')" "$archive" \
  "$(du -h "$archive" | cut -f1)" "$(ls -1 "$DEST"/auto-arr-*.tar.gz | wc -l | tr -d ' ')"

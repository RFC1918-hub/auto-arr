# auto-arr

One command installs and wires a complete media-automation stack on any Linux
server with Docker: **Prowlarr, Radarr, Sonarr, Jellyseerr, Jellyfin and
qBittorrent** — APIs connected, folders created, libraries scanned.

## Quick start

```bash
git clone <this-repo> && cd auto-arr
./setup.sh
```

That's it. When the script finishes it prints each service's URL.
Logins are in `credentials.txt` (git-ignored, generated on first run).

**Requirements:** Linux, Docker Engine + compose plugin. Nothing else.

## What gets wired

- Prowlarr → Radarr + Sonarr (full sync — add an indexer in Prowlarr and it
  appears in both automatically)
- Radarr/Sonarr → qBittorrent (categories `movies`/`tv`) + root folders
- Jellyfin → admin user created, Movies + Shows libraries added and scanned
- Jellyseerr → connected to Jellyfin, Radarr and Sonarr
- Folder layout follows the TRaSH-guides single-volume convention, so
  completed downloads are **hardlinked** into the library (no copy, no
  double disk usage):

```
data/
├── torrents/{movies,tv}   # qBittorrent downloads
└── media/{movies,tv}      # your libraries
config/<app>/              # each app's config
```

## After install

1. Open Prowlarr and add your indexers — that's the only manual step.
2. Request something in Jellyseerr and watch it flow through.

## Operations

- **Re-run safely:** `./setup.sh` is idempotent — it repairs/resumes, never duplicates.
- **Regenerate secrets:** delete `.env` and `config/`, then re-run (full reset).
- **Change ports/paths:** edit `.env`, then `docker compose up -d`.
- **Logs:** `docker logs <service>`; wiring log: `docker logs arr-bootstrap`.
- **Uninstall:** `docker compose down` (add `-v` plus delete `config/` and `data/` for a full wipe).

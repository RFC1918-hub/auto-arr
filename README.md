# auto-arr

One command installs and wires a complete media-automation stack on any Linux
server with Docker: **Prowlarr (+ FlareSolverr), Radarr, Sonarr, Seerr (formerly
Jellyseerr), Jellyfin and qBittorrent** — APIs connected, folders created,
libraries scanned.

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
- Prowlarr → FlareSolverr indexer proxy, attached to the tag `flaresolverr`,
  for indexers behind Cloudflare protection
- Radarr/Sonarr → qBittorrent (categories `movies`/`tv`) + root folders
- Seeding cleanup: qBittorrent pauses a torrent at ratio 1.0 or after 24 h
  (whichever first; `SEED_RATIO` / `SEED_TIME_MINUTES` in `.env`), and
  Radarr/Sonarr then delete it and its files once imported. Library copies are
  hardlinks and are untouched.
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

1. Open Prowlarr and add your indexers — that's the only manual step. If one
   fails with *blocked by CloudFlare Protection* (1337x, for example), add the
   `flaresolverr` tag to that indexer so Prowlarr routes it through FlareSolverr.
2. Request something in Jellyseerr and watch it flow through.

## Operations

- **Re-run safely:** `./setup.sh` is idempotent — it repairs/resumes, never duplicates.
- **Regenerate secrets:** delete `.env` and `config/`, then re-run (full reset).
- **Change ports/paths:** edit `.env`, then `docker compose up -d`.
- **Change seeding limits:** edit `SEED_RATIO` / `SEED_TIME_MINUTES` in `.env`
  (0 disables one), then re-run `./setup.sh`.
- **Logs:** `docker logs <service>`; wiring log: `docker logs arr-bootstrap`.
- **Uninstall:** `docker compose down` (add `-v` plus delete `config/` and `data/` for a full wipe).

# auto-arr — One-Command Arr-Stack Installer (Design)

**Date:** 2026-08-11
**Status:** Approved

## Purpose

A single command (`./setup.sh`) on any Linux server with Docker installs and fully
wires a media-automation stack: Prowlarr, Radarr, Sonarr, Jellyseerr, Jellyfin, and
qBittorrent. When the script finishes, every service is connected to every other via
their APIs, media folders exist in a hardlink-friendly layout, and Jellyfin has
scanned its (empty) libraries. Comparable UX to seedbox.fr's one-click app bundle,
but self-hosted and portable.

## Constraints

- Target: Linux servers only. Only host dependencies: Docker Engine + compose plugin.
- Zero prompts: `./setup.sh` runs end-to-end with sane defaults; overrides via `.env`.
- Idempotent: re-running is always safe and resumes/repairs rather than duplicates.
- Secrets never committed: `.env` and `credentials.txt` are git-ignored.

## Architecture (Approach B — approved)

`setup.sh` on the host does only: preflight checks, `.env` generation, folder
creation, `docker compose up -d`. All API wiring runs in a **one-shot bootstrap
container** (curl + jq) on the same Docker network, reaching services via internal
DNS (`http://radarr:7878`), so published ports and host firewalls are irrelevant to
wiring.

Deterministic keys: arr API keys are generated once into `.env` and injected via
env vars (`RADARR__AUTH__APIKEY`, `SONARR__AUTH__APIKEY`, `PROWLARR__AUTH__APIKEY`),
so the bootstrap never scrapes `config.xml`.

## Repo Layout

```
auto-arr/
├── setup.sh              # entry point — the only thing the user runs
├── docker-compose.yml    # static; all variability lives in .env
├── .env.example          # documented defaults
├── bootstrap/
│   └── bootstrap.sh      # API wiring, runs inside the one-shot container
├── .gitignore            # .env, credentials.txt, config/, data/
└── README.md
```

## Runtime Layout (created by setup.sh)

```
config/<app>/                       # one dir per service, bind-mounted
data/torrents/{movies,tv}          # qBittorrent download dirs (categories)
data/media/{movies,tv}             # library roots (Radarr/Sonarr/Jellyfin)
```

Single `data` volume shared by qBittorrent, Radarr, Sonarr, Jellyfin →
imports are instant hardlinks (TRaSH-guides convention).

## Services

All linuxserver.io images except Jellyseerr (`fallenbagel/jellyseerr`).
One user-defined bridge network `arr`.

| Service     | Port | Config injection                          |
|-------------|------|-------------------------------------------|
| qBittorrent | 8080 | password set by bootstrap via WebUI API    |
| Prowlarr    | 9696 | `PROWLARR__AUTH__APIKEY` from `.env`       |
| Radarr      | 7878 | `RADARR__AUTH__APIKEY` from `.env`         |
| Sonarr      | 8989 | `SONARR__AUTH__APIKEY` from `.env`         |
| Jellyfin    | 8096 | first-run wizard completed by bootstrap    |
| Jellyseerr  | 5055 | initialized by bootstrap                   |
| bootstrap   | —    | one-shot; exits 0 when stack fully wired   |

`PUID/PGID/TZ` auto-detected by setup.sh into `.env`.

## setup.sh Responsibilities

1. Preflight: docker present, compose plugin present, required ports free;
   clear failure message per check.
2. First run only: generate `.env` from `.env.example` — random 32-hex API keys
   (Radarr, Sonarr, Prowlarr), random passwords (Jellyfin admin, qBittorrent),
   detected `TZ`, `PUID`, `PGID`. Never regenerate an existing `.env`.
3. Write `credentials.txt` (git-ignored) with all generated credentials.
4. Create the runtime folder tree.
5. `docker compose up -d`, then follow the bootstrap container's logs and
   propagate its exit code.
6. Print service URLs and where credentials live.

## bootstrap.sh Steps (each idempotent: GET first, POST only if missing)

1. Wait for each service's health/ping endpoint (timeout 120 s per service,
   named failure message pointing at `docker logs <svc>`).
2. qBittorrent: set the known password from `.env`
   (handle the temp-password flow of qBittorrent ≥ 4.6), create categories
   `movies` → `/data/torrents/movies`, `tv` → `/data/torrents/tv`.
3. Radarr: root folder `/data/media/movies`; qBittorrent as download client
   (category `movies`).
4. Sonarr: root folder `/data/media/tv`; qBittorrent as download client
   (category `tv`).
5. Prowlarr: add Radarr and Sonarr as Applications with full sync — indexers
   added later in Prowlarr propagate automatically.
6. Jellyfin: complete first-run wizard via `/Startup/*` endpoints (create admin
   user from `.env`), create libraries Movies → `/data/media/movies` and
   Shows → `/data/media/tv`, trigger a library scan.
7. Jellyseerr: initialize against Jellyfin (authenticate as the admin user),
   register Radarr and Sonarr with their default quality profiles and root
   folders, mark setup complete.
8. Print a wiring summary; exit 0 only if every step verified.

## Error Handling

- Every wait loop has a timeout and names the failing service and the command
  to inspect it.
- Bootstrap failure never tears anything down; `./setup.sh` re-run resumes —
  completed steps detect existing state and skip.
- setup.sh uses `set -euo pipefail`; bootstrap reports step-level context on exit.

## Testing

- `shellcheck` clean on `setup.sh` and `bootstrap/bootstrap.sh`.
- Acceptance test on a clean Linux host (or fresh VM/WSL2): clone →
  `./setup.sh` → verify: all six UIs reachable; Prowlarr lists 2 apps;
  Radarr/Sonarr each show 1 download client + 1 root folder; Jellyfin has
  2 libraries and admin login works; Jellyseerr shows Jellyfin + both arrs.
- Idempotency test: run `./setup.sh` twice; second run makes no duplicate
  objects and exits 0.

## Out of Scope (YAGNI)

No VPN container, no reverse proxy/HTTPS, no indexer auto-provisioning (requires
personal accounts), no Windows/macOS support, no update/backup tooling, no
notification integrations.

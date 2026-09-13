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

**Requirements:** Linux, Docker Engine + compose plugin. Nothing else. Run it
with `sudo` as your normal user (not from a root shell) so media is owned by you.

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
- Radarr/Sonarr → Jellyfin: the library is refreshed the moment something is
  imported, upgraded, renamed or deleted (no waiting for a scheduled scan)
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
- **Update apps:** images are pinned to verified versions. Bump the tags in
  `docker-compose.yml`, then re-run `./setup.sh`.
- **Backups:** `scripts/backup.sh` archives `config/`, `.env` and
  `credentials.txt` into `backups/` and keeps the last 7. Nightly:
  `30 4 * * * /opt/auto-arr/scripts/backup.sh`.
- **Remote access:** keep the ports LAN-only. For access from outside, run
  Tailscale or WireGuard on the host rather than port-forwarding on the router.

## Running on Windows (WSL2)

The stack runs unchanged inside a WSL2 Ubuntu distro with Docker Engine
installed in it (systemd enabled in `/etc/wsl.conf`). Two Windows-side
details make it behave like a server:

- **Stay up and be reachable.** WSL stops a distro about a minute after its
  last session ends (even with systemd inside), and its default NAT networking
  exposes ports to the Windows host only. `scripts/windows/wsl-keepalive.ps1`
  handles both: it starts the distro, points Windows port proxies for the six
  stack ports at the distro's current address, then holds a session open.
  Install it once from an elevated PowerShell as a task that runs at startup
  and at logon, whether or not anyone is logged on (the S4U logon type needs
  no stored password):

  ```powershell
  New-Item -ItemType Directory -Force C:\ProgramData\auto-arr | Out-Null
  Copy-Item '\\wsl$\Ubuntu\opt\auto-arr\scripts\windows\wsl-keepalive.ps1' C:\ProgramData\auto-arr\
  foreach ($p in 8096,5055,9696,7878,8989,8080) {
    New-NetFirewallRule -Name "auto-arr-$p" -DisplayName "auto-arr $p" -Direction Inbound -Protocol TCP -LocalPort $p -Action Allow
  }
  Register-ScheduledTask -TaskName 'auto-arr WSL keepalive' `
    -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\auto-arr\wsl-keepalive.ps1') `
    -Trigger @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)) `
    -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest) `
    -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1))
  Start-ScheduledTask -TaskName 'auto-arr WSL keepalive'
  ```

  The script logs to `C:\ProgramData\auto-arr\keepalive.log`. (WSL's mirrored
  networking mode would make the proxies unnecessary, but in testing it did
  not pass LAN traffic through to Docker-published ports.)
- **Disk.** Keep `DATA_ROOT` inside the WSL filesystem: hardlinks do not work
  on `/mnt/c`. The virtual disk grows on demand up to its limit (1 TB by
  default) and is bounded by free space on the Windows drive.

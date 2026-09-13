# auto-arr on Windows (WSL2): keep the distro running and expose the stack on the LAN.
#
# WSL terminates a distro about a minute after its last session ends, even with
# systemd inside, so this script holds a 'sleep infinity' session open for as long as
# it runs. Before that it points Windows port proxies at the distro's current NAT
# address (which changes across reboots), so the machine's LAN address forwards to the
# stack. Windows Firewall must allow the ports (rules auto-arr-<port>, see README).
#
# Install as a Task Scheduler task (run whether the user is logged on or not, no
# password needed with the S4U logon type, highest privileges for netsh), triggered at
# system startup and at logon:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\auto-arr\wsl-keepalive.ps1
param(
  [string]$Distro = 'Ubuntu',
  [int[]]$Ports = @(3000, 8096, 5055, 9696, 7878, 8989, 8080),
  [string]$LogFile = 'C:\ProgramData\auto-arr\keepalive.log'
)
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $LogFile }

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
Log "starting distro $Distro"
wsl.exe -d $Distro -u root --exec /bin/true

# wait for Docker inside the distro (systemd starts it on boot)
$docker = ''
for ($i = 0; $i -lt 60 -and $docker -ne 'active'; $i++) {
  Start-Sleep -Seconds 2
  $docker = (wsl.exe -d $Distro -u root --exec systemctl is-active docker 2>$null | Out-String).Trim()
}
Log "docker: $docker"

# forward the LAN address to the distro's current NAT address
$ip = ((wsl.exe -d $Distro -u root --exec hostname -I | Out-String).Trim() -split '\s+')[0]
if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
  foreach ($p in $Ports) {
    netsh interface portproxy delete v4tov4 listenport=$p listenaddress=0.0.0.0 | Out-Null
    netsh interface portproxy add v4tov4 listenport=$p listenaddress=0.0.0.0 connectport=$p connectaddress=$ip | Out-Null
  }
  Log "port proxies 0.0.0.0:{$($Ports -join ',')} -> $ip"
} else {
  Log "could not determine the distro's IP ('$ip'); port proxies left unchanged"
}

# hold the distro open for as long as this task runs
Log "holding distro open"
wsl.exe -d $Distro -u root --exec /bin/sh -c 'sleep infinity'
Log "keepalive session ended"

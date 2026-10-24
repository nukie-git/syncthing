# Syncthing Portable — Continuous File Synchronization

## Overview

[Syncthing](https://syncthing.net) is an open-source, continuous peer-to-peer file synchronization client and server. It synchronizes files in real time between two or more computers securely, encrypting all communication via TLS.

In the **Stargazer Media Services** ecosystem, Syncthing is deployed as a portable service running in Tier 2 (Content & Files). It listens locally on port `8384` for web management and port `22000` for synchronization, reverse-proxied behind Caddy under both dedicated subdomains and path prefix `/syncthing`.

---

## Technical Specifications

| Parameter | Configuration Value |
| :--- | :--- |
| **Server Binary** | [`syncthing.exe`](file:///C:/PortableApps/syncthing/syncthing.exe) |
| **Web GUI Port** | `8384` (`127.0.0.1:8384`) |
| **Sync Protocol Port** | `22000` (`TCP` / `QUIC`) |
| **Local Discovery** | `21027/UDP` |
| **Data & Config Directory** | [`C:\PortableApps\syncthing\data`](file:///C:/PortableApps/syncthing/data) |
| **Configuration File** | [`C:\PortableApps\syncthing\data\config.xml`](file:///C:/PortableApps/syncthing/data/config.xml) |
| **Reverse Proxy Subpath** | `/syncthing` & `/syncthing/` |
| **Reverse Proxy Subdomain** | `syncthing.{TAILSCALE_HOSTNAME}`, `syncthing.local`, `syncthing.home` |
| **Startup Tier** | Tier 2 (Content & Files) in [`master-boot-launcher.ps1`](file:///C:/PortableApps/master-boot-launcher.ps1) |
| **Elevated Sentinel Flag** | [`syncthing.flag`](file:///C:/PortableApps/syncthing/syncthing.flag) |

---

## Directory Architecture

```
C:\PortableApps\syncthing\
├── data/                            # Portable configuration, SSL certs, index databases & logs
│   ├── index-v2/                    # Syncthing block/folder index database (LevelDB)
│   ├── cert.pem / key.pem           # Device cryptographic identity certificates
│   ├── https-cert.pem / https-key.pem
│   ├── config.xml                   # Core XML configuration (GUI, folders, devices)
│   ├── syncthing.lock               # Process runtime lock
│   └── syncthing.log                # Service runtime output log
├── etc/                             # Platform service definitions & firewall helpers
├── syncthing-start.vbs              # Silent WMI detached background launcher
├── syncthing-stop.vbs               # Graceful REST API shutdown with elevated fallback
├── syncthing-update.ps1             # Universal 6-step automated GitHub update engine
├── syncthing.exe                    # Core compiled Go binary
└── README.md                        # Technical documentation (this file)
```

---

## Operational Workflows & Scripts

### 1. Silent Background Launcher (`syncthing-start.vbs`)
Starts Syncthing completely detached from the calling terminal via **WMI `Win32_Process.Create`** (`parent PID 4 / System`), making it immune to parent-shell and subshell teardowns when Antigravity or PowerShell closes.

- Cleans up any stale sentinel flags (`syncthing.flag`).
- Checks for existing running instances via native WMI query (idempotent guard).
- Sets home directory to `./data`:
  ```cmd
  syncthing.exe serve --no-browser --no-console --home="C:\PortableApps\syncthing\data"
  ```
- Usage:
  ```cmd
  wscript.exe "C:\PortableApps\syncthing\syncthing-start.vbs"
  ```

### 2. Graceful Shutdown Script (`syncthing-stop.vbs`)
Shuts down Syncthing safely to prevent index database corruption:
1. Calls the REST API shutdown endpoint:
   ```powershell
   Invoke-RestMethod -Uri "http://127.0.0.1:8384/rest/system/shutdown" -Headers @{"X-API-Key"="<api-key>"} -Method Post
   ```
2. Terminates any remaining `syncthing` process tree instances.
3. If port `8384` remains bound under Session 0 / `SYSTEM` (NSSM), drops elevated sentinel flag `syncthing.flag` and triggers `StargazerWinGetElevatedUpdater`.
- Usage:
  ```cmd
  wscript.exe "C:\PortableApps\syncthing\syncthing-stop.vbs" /silent
  ```

### 3. Automated GitHub Update Engine (`syncthing-update.ps1`)
Implements the Stargazer Universal 6-Step Updater Architecture (`UpdateHelpers.psm1`):
1. **GitHub Auth Discovery**: Reads GitHub Desktop token from Windows Credential Manager to raise rate limit to 5,000 req/hr.
2. **Pre-Update Cleanup**: Purges superseded backups in `.update_cache\backup` to preserve disk space.
3. **Local Downloads Check**: Scans user Downloads folder for matching `syncthing-windows-amd64-*.zip` before downloading.
4. **Accelerated Multi-Stream**: Uses `aria2c` multi-stream (`-s 4 -x 4 -k 1M`) with curl and Invoke-WebRequest fallback.
5. **Session 0 Sentinel Stop Guard**: Stops Syncthing via `syncthing-stop.vbs /silent` and enforces a 2-second OS handle release cooldown.
6. **Atomic Replacement & Health Probe**: Swaps `syncthing.exe` with a 5-attempt retry loop, restarts via `syncthing-start.vbs`, and validates health on port `8384` for 30 seconds.

- Command-Line Usage:
  ```powershell
  # Check for updates without downloading
  powershell.exe -ExecutionPolicy Bypass -File .\syncthing-update.ps1 -CheckOnly

  # Upgrade to the latest release
  powershell.exe -ExecutionPolicy Bypass -File .\syncthing-update.ps1

  # Force reinstall current version
  powershell.exe -ExecutionPolicy Bypass -File .\syncthing-update.ps1 -Force
  ```

---

## Caddy Reverse Proxy & Network Routing

Syncthing is routed through Caddy with automatic `Host` header rewrites (`header_up Host 127.0.0.1:8384`) to satisfy Syncthing's CSRF/Host verification without weakening security:

1. **Dedicated Subdomains**:
   - `https://syncthing.<tailscale-host>` (Internal CA TLS / public Tailscale cert)
   - `http://syncthing.local` & `http://syncthing.home` (Port 80 LAN HTTP)
2. **Subpath Prefix**:
   - `/syncthing` &rarr; Redirects to `/syncthing/` (302)
   - `/syncthing/*` &rarr; Strips prefix and proxies to upstream `127.0.0.1:8384`
   - Access restricted to trusted CIDRs (`127.0.0.1/8`, `192.168.0.0/16`, `100.64.0.0/10`, `10.0.0.0/8`, `172.16.0.0/12`).

---

## Admin Dashboard & Portal Integration

- **Media Portal Card**: Displays on `index.html` with official brand vector icon ([`icons/syncthing.svg`](file:///C:/PortableApps/caddy/www/icons/syncthing.svg)), real-time online/offline status badge, and direct link to `/syncthing`.
- **Admin Dashboard**: Managed from the Services panel (`#services`) with status reporting, version tag display, Start/Stop controls, and one-click GitHub upgrade execution.
- **Portal Visibility Manager**: Toggleable in the Portal Cards tab (`#visibility`) via `PORTAL_CARDS["syncthing"]`.

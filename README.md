# Syncthing — Continuous File Synchronization (Linux VPS Edition)

## Overview

[Syncthing](https://syncthing.net) is an open-source, continuous peer-to-peer file synchronization client and server. It synchronizes files in real time between two or more computers securely, encrypting all communication via TLS.

In the **Stargazer Media Services** Linux VPS ecosystem (`stargazer.stargazer-bichir.ts.net`), Syncthing is deployed as a managed systemd service running in **Tier 2 (Content & Files)** under user `nukie`. It listens locally on port `8384` for web management and port `22000` for synchronization, reverse-proxied behind Caddy under both dedicated subdomains and path prefix `/syncthing`.

---

## Technical Specifications

| Parameter | Configuration Value |
| :--- | :--- |
| **Server Binary** | `/usr/local/bin/syncthing` (Symlinked to `/home/nukie/.local/bin/syncthing`) |
| **Systemd Service** | `/etc/systemd/system/syncthing.service` |
| **Run As User / Group** | `nukie:nukie` |
| **Web GUI Port** | `8384` (`127.0.0.1:8384`) |
| **Sync Protocol Port** | `22000` (`TCP` / `QUIC`) |
| **Local Discovery** | `21027/UDP` |
| **Data & Config Directory** | `/home/nukie/.local/state/syncthing` |
| **Configuration File** | `/home/nukie/.local/state/syncthing/config.xml` |
| **Reverse Proxy Subpath** | `/syncthing` & `/syncthing/` |
| **Reverse Proxy Subdomains** | `syncthing.stargazer.stargazer-bichir.ts.net`, `syncthing.local`, `syncthing.home` |
| **Startup Tier** | Tier 2 (Content & Files) &bull; Master Boot Step `9.5` |
| **Admin Service Key** | `"syncthing"` in `KNOWN_SERVICES` (`/opt/stargazer/admin/main.py`) |

---

## Directory Architecture

```
/home/nukie/.local/state/syncthing/
├── cert.pem / key.pem           # Device cryptographic identity certificates
├── https-cert.pem / https-key.pem
├── config.xml                   # Core XML configuration (GUI, folders, devices)
├── index-v2/                    # Syncthing block/folder index database (LevelDB)
├── syncthing.lock               # Process runtime lock
└── syncthing.log                # Service runtime output log

/etc/systemd/system/
└── syncthing.service            # System systemd service unit

/opt/stargazer/caddy/www/
├── icons/syncthing.svg          # High-resolution vector logo
└── services.json                # Bento Grid catalog card definition
```

---

## Service Lifecycle Management

Syncthing runs as a managed system systemd service (`syncthing.service`):

```bash
# Check service status
sudo systemctl status syncthing

# Start / Stop / Restart service
sudo systemctl start syncthing
sudo systemctl stop syncthing
sudo systemctl restart syncthing

# Check if auto-start on boot is enabled
sudo systemctl is-enabled syncthing
```

### Automated Upgrade Engine
Syncthing features a built-in automated in-place upgrade mechanism. In the Stargazer Admin Dashboard, clicking **Update** executes:
```bash
syncthing upgrade
sudo systemctl restart syncthing
```
And online version checking is automatically evaluated against GitHub releases (`syncthing/syncthing`).

---

## Caddy Reverse Proxy & Network Routing

Syncthing is routed through Caddy with automatic `Host` header rewrites (`header_up Host 127.0.0.1:8384`) to satisfy Syncthing's CSRF/Host verification without weakening security:

1. **Dedicated Subdomains**:
   - `https://syncthing.stargazer.stargazer-bichir.ts.net` (Internal CA TLS / public Tailscale cert)
   - `http://syncthing.local` & `http://syncthing.home` (Port 80 LAN HTTP)
2. **Subpath Prefix**:
   - `/syncthing` &rarr; Redirects to `/syncthing/` (302)
   - `/syncthing/*` &rarr; Strips prefix and proxies to upstream `127.0.0.1:8384`
   - Access restricted to trusted CIDRs (`127.0.0.1/8`, `192.168.0.0/16`, `100.64.0.0/10`, `10.0.0.0/8`, `172.16.0.0/12`).

---

## Bento Media Portal & Admin Dashboard Integration

- **Bento Media Portal**: Configured in `/opt/stargazer/caddy/www/services.json` under the `"files"` category with brand SVG icon (`/icons/syncthing.svg`), accent colors (`#0882c8`), and real-time health badge.
- **Admin Dashboard**: Managed from the Services panel (`#services`) with status reporting, version tag display (`v2.1.7`), Start/Stop controls, and one-click GitHub upgrade execution.
- **Portal Visibility Manager**: Toggleable in the Portal Cards tab (`#visibility`) via `PORTAL_CARDS["syncthing"]`.
- **Master Boot Ordering**: Listed under Step `9.5` in the Master Boot panel.

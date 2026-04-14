# Git Backup — Unraid Plugin

Back up your Docker container configs, Home Assistant OS configs, Docker Compose files, and Unraid system settings to a git repository — automatically, on a schedule, with smart rules that know what to include and what to skip.

## Why?

Existing Unraid backup solutions (`CA Backup`, `Appdata Backup`) tar your **entire** appdata folder — databases, caches, thumbnails, and all. That's huge, slow, and not version-controlled.

**Git Backup** does the opposite: it extracts only the small configuration files that actually matter, commits them to a git repo, and pushes to your remote. If something breaks, you have a full history of every config change, diffable and restorable.

## Features

- **Smart config extraction** — Built-in knowledge base for 22+ popular containers (Plex, Radarr, Sonarr, Jellyfin, Home Assistant, etc.) knows exactly which files are config vs. cache/data
- **Three-tier rule priority** — Global defaults → knowledge base → per-container overrides. No merging, no confusion — highest priority wins
- **Home Assistant OS backup** — Pulls HAOS config via SSH (configuration.yaml, automations, .storage registries, custom_components, etc.)
- **Docker Compose backup** — Backs up all compose project files from Compose Manager
- **Unraid system config** — Captures go script, network, disk, share, samba, and boot configs
- **Git versioning** — Every backup is a commit with timestamp and change summary. Full diff history of every config change
- **Scheduled + on-demand** — Cron-based scheduling (default: daily 3 AM) plus manual run from the WebUI
- **Dry run mode** — Preview exactly what would be backed up without touching anything
- **Unraid notifications** — Success/failure alerts via Unraid's built-in notification system
- **Unraid WebUI settings page** — Configure everything from Settings → Utilities → Git Backup

## What Gets Backed Up

| Source | What's included | What's excluded |
|--------|----------------|-----------------|
| **Appdata** | Config files (`.xml`, `.yaml`, `.json`, `.conf`, `.ini`) | Databases, caches, logs, media, thumbnails |
| **Compose** | All files in compose project dirs | — |
| **HAOS** | `configuration.yaml`, automations, scripts, `.storage/` registries, custom_components, blueprints, themes | `home-assistant_v2.db`, `tts/`, `deps/`, `backups/` |
| **Unraid** | `go`, `network.cfg`, `disk.cfg`, `share.cfg`, `smb-extra.conf`, `syslinux.cfg` | — |

## Installation

### From URL (recommended)

1. In Unraid WebUI: **Plugins → Install Plugin**
2. Paste:
   ```
   https://raw.githubusercontent.com/YOUR_USER/unraid-plugin-git-backup/main/git-backup.plg
   ```
3. Click **Install**

### Manual

```bash
# On your Unraid server
plugin install https://raw.githubusercontent.com/YOUR_USER/unraid-plugin-git-backup/main/git-backup.plg
```

## Setup

### 1. Create a private repo for your configs

Create a new **private** repository on GitHub/GitLab/Gitea (e.g., `unraid-configs`). This is where your backed-up configs will be pushed — separate from this plugin's source repo.

### 2. Generate SSH key (automatic)

In the plugin settings page (**Settings → Utilities → Git Backup**):

1. Click **Generate Git SSH Key** — the plugin generates an ed25519 key and stores it on the USB flash drive (persistent across reboots)
2. Copy the public key shown in the popup
3. Add it to your Git provider (GitHub → Settings → SSH Keys → New SSH Key)

> **Note:** Keys are stored on `/boot/config/plugins/git-backup/ssh/` (USB flash) and automatically copied to `/root/.ssh/` on every boot. No manual SSH config needed.

### 3. Configure the plugin

In the same settings page:

- **Remote URL**: `git@github.com:YOUR_USER/unraid-configs.git`
- Adjust any other settings as needed
- Click **Apply**

### 4. Initialize and test

1. Click **Initialize Repo** — creates the local git repo and tests the remote push
2. Click **Dry Run** — previews what would be backed up
3. Click **Run Backup Now** — performs the first real backup

## Configuration

### Three-Tier Priority System

Rules are resolved per-container with a winner-takes-all approach (no merging between tiers):

| Priority | Source | Description |
|----------|--------|-------------|
| 3 (highest) | **User overrides** | `OVERRIDE_<NAME>_*` keys in config |
| 2 | **Knowledge base** | Built-in rules for known containers |
| 1 (lowest) | **Global defaults** | `GLOBAL_EXCLUDE` patterns |

### Per-Container Overrides

Add to `/boot/config/plugins/git-backup/git-backup.cfg`:

```ini
# Include mode: only back up these files
OVERRIDE_PLEX_MEDIA_SERVER_INCLUDE="Library/Application Support/Plex Media Server/Preferences.xml"

# Exclude mode: back up everything except these
OVERRIDE_MY_CONTAINER_EXCLUDE="cache/**,*.log,tmp/**"
```

Folder name mapping: uppercase, replace `-`, `.`, and spaces with `_`.
- `Plex-Media-Server` → `PLEX_MEDIA_SERVER`
- `binhex-prowlarr` → `BINHEX_PROWLARR`

### HAOS Setup

1. Install the **Advanced SSH & Web Terminal** add-on in Home Assistant
2. In the plugin settings, click **Generate HAOS SSH Key**
3. Copy the public key shown in the popup
4. In Home Assistant: **Settings → Add-ons → Advanced SSH & Web Terminal → Configuration**
5. Paste the public key into the **Authorized keys** field
6. Restart the SSH add-on
7. Back in the plugin settings, set **Enable HAOS Backup → Yes** and click **Apply**
8. Click **Dry Run** to verify the SSH connection works

### Schedule

Default: daily at 3 AM (`0 3 * * *`).

Examples:
- `0 */6 * * *` — every 6 hours
- `0 3 * * 1` — weekly on Monday at 3 AM
- `*/30 * * * *` — every 30 minutes

## CLI Usage

```bash
# Manual backup
/usr/local/emhttp/plugins/git-backup/rc.git-backup run

# Dry run with verbose output
/usr/local/emhttp/plugins/git-backup/rc.git-backup run --dry-run --verbose

# Check cron status
/usr/local/emhttp/plugins/git-backup/rc.git-backup status

# View recent backup log
tail -50 /var/log/git-backup.log

# View config change history
cd /mnt/user/appdata/git-config-backup
git log --oneline -20
git diff HEAD~1    # see what changed in last backup
```

## Backup Repo Structure

```
git-config-backup/
├── appdata/
│   ├── Plex-Media-Server/
│   │   └── Library/.../Preferences.xml
│   ├── radarr/
│   │   └── config.xml
│   ├── zigbee2mqtt/
│   │   ├── configuration.yaml
│   │   └── devices.yaml
│   └── ...
├── compose/
│   ├── media-stack/
│   │   └── docker-compose.yml
│   └── ...
├── haos/
│   ├── configuration.yaml
│   ├── automations.yaml
│   └── .storage/
│       ├── core.config_entries
│       └── core.device_registry
└── unraid/
    ├── go
    ├── network.cfg
    └── disk.cfg
```

## Supported Containers (Knowledge Base)

The built-in knowledge base has optimized rules for:

| Container | Strategy | Key files |
|-----------|----------|-----------|
| Plex | Include-only | `Preferences.xml` |
| Radarr / Sonarr | Include-only | `config.xml`, `*.xml` |
| Prowlarr | Include-only | `Prowlarr/config.xml` |
| Jellyfin | Exclude caches | Skips `cache/`, `metadata/`, `data/` |
| qBittorrent (binhex) | Include-only | `qBittorrent.conf`, wireguard/openvpn configs |
| SABnzbd | Include-only | `sabnzbd.ini`, `*.conf` |
| Zigbee2MQTT | Include-only | `configuration.yaml`, `devices.yaml`, `groups.yaml` |
| Z-Wave JS UI | Include-only | `settings.json`, `*.json` |
| Mosquitto | Include-only | `config/**` |
| Nginx Proxy Manager | Exclude DBs | Skips `*.db`, `log/` |
| Tdarr | Include-only | `configs/**` |
| Homarr | Exclude DBs | Skips `*.db` |
| Immich | Exclude data | Skips `thumbs/`, `encoded-video/`, `machine-learning/` |

Unknown containers use global exclude rules (databases, caches, logs, media files).

## Building from Source

```bash
git clone https://github.com/YOUR_USER/unraid-plugin-git-backup.git
cd unraid-plugin-git-backup
./build.sh 2026.04.13    # creates archive/git-backup-2026.04.13.txz
```

## Plugin File Layout

```
/usr/local/emhttp/plugins/git-backup/    # Plugin code (RAM, wiped on reboot)
├── git-backup.page                       # WebUI settings page
├── scripts/
│   ├── backup.sh                         # Main backup script
│   ├── init-repo.sh                      # Repo initializer
│   └── parse-yaml.sh                     # YAML parser for knowledge base
├── data/
│   └── container-knowledge.yml           # Built-in container rules
├── event/
│   └── started                           # Reinstalls cron after reboot
└── rc.git-backup                         # Service control

/boot/config/plugins/git-backup/          # Config (USB flash, persists)
└── git-backup.cfg                        # User settings (INI format)
```

## License

MIT

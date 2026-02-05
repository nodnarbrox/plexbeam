# Linux Plex Server Setup Guide

This guide covers installing the PlexBeam cartridge on your Linux Plex server.

## Prerequisites

- Plex Media Server installed and running
- Root/sudo access
- `curl` and `jq` installed (for remote dispatch)
- Network access to your GPU worker

## Quick Install

```bash
# Clone or download the repository
git clone https://github.com/yourusername/plexbeam.git
cd plexbeam/cartridge

# Install with remote worker
sudo ./install.sh --worker http://192.168.1.100:8765

# Or install without remote (local transcoding only)
sudo ./install.sh
```

## Installation Options

### Basic Install (Local Only)

```bash
sudo ./install.sh
```

This installs the cartridge for monitoring and analysis only. Transcoding uses Plex's local transcoder.

### Install with Remote GPU Worker

```bash
sudo ./install.sh --worker http://192.168.1.100:8765
```

Replace `192.168.1.100:8765` with your GPU worker's address.

### Install with Authentication

```bash
sudo ./install.sh \
  --worker http://192.168.1.100:8765 \
  --api-key your-secret-key
```

### Install with Auto-Updates

```bash
sudo ./install.sh \
  --worker http://192.168.1.100:8765 \
  --repo https://github.com/yourusername/plexbeam
```

### All Options

```
Usage: sudo ./install.sh [OPTIONS]

Remote GPU Options:
  --worker URL       Remote GPU worker URL (e.g., http://192.168.1.100:8765)
  --api-key KEY      API key for worker authentication
  --shared-dir PATH  Shared directory for segment output (SMB/NFS mount)

Update Options:
  --repo URL         GitHub repo or local path for auto-updates

Other Options:
  --no-watchdog      Skip watchdog installation
```

## What Gets Installed

| Component | Location | Purpose |
|-----------|----------|---------|
| Cartridge scripts | `/opt/plex-cartridge/` | Cartridge home directory |
| Active cartridge | `/usr/lib/plexmediaserver/Plex Transcoder` | Replaces Plex's binary |
| Real transcoder | `/usr/lib/plexmediaserver/Plex Transcoder.real` | Backup of original |
| Session logs | `/var/log/plex-cartridge/sessions/` | Per-transcode logs |
| Master log | `/var/log/plex-cartridge/master.log` | One line per transcode |
| Event log | `/var/log/plex-cartridge/cartridge_events.log` | System events |
| Watchdog service | `plex-cartridge-watchdog.service` | Systemd service |

## Verify Installation

```bash
# Check cartridge is in place
file "/usr/lib/plexmediaserver/Plex Transcoder"
# Should say "Bourne-Again shell script" not "ELF executable"

# Check watchdog is running
sudo systemctl status plex-cartridge-watchdog

# Check worker connectivity
curl http://192.168.1.100:8765/health
```

## Configuration Files

### Install Metadata

```bash
cat /var/log/plex-cartridge/.install_meta
```

Contains:
- `REMOTE_WORKER_URL` - Worker address
- `REMOTE_API_KEY` - Authentication key
- `CARTRIDGE_VERSION` - Installed version
- `PLEX_VERSION` - Detected Plex version

### Reconfiguring Remote Worker

To change the remote worker URL:

```bash
# Re-run installer with new settings
sudo /opt/plex-cartridge/install.sh --worker http://new-worker:8765
```

Or edit directly and reinstall:

```bash
sudo vim /opt/plex-cartridge/plex_cartridge.sh
# Change REMOTE_WORKER_URL line
sudo /opt/plex-cartridge/watchdog.sh --once
```

## Monitoring

### View Recent Transcodes

```bash
tail -20 /var/log/plex-cartridge/master.log
```

Output format:
```
2025-02-05T14:30:22+00:00 | exit=0 | dur=1234ms | mode=remote | codec=h264 | type=hls | input=movie.mkv
```

### Analyze Sessions

```bash
# Summary of all sessions
sudo /opt/plex-cartridge/analyze.sh

# Check if remote transcoding is viable
sudo /opt/plex-cartridge/analyze.sh --remote-feasibility

# View specific session details
sudo /opt/plex-cartridge/analyze.sh --detail 20250205_143022_12345
```

### Check Events

```bash
# Recent events
tail -50 /var/log/plex-cartridge/cartridge_events.log

# Watch live
tail -f /var/log/plex-cartridge/cartridge_events.log
```

## Troubleshooting

### Cartridge Not Intercepting

```bash
# Verify installation
file "/usr/lib/plexmediaserver/Plex Transcoder"
# Should be: ASCII text, shell script

# Check logs for errors
tail /var/log/plex-cartridge/cartridge_events.log

# Manual health check
sudo /opt/plex-cartridge/watchdog.sh --once
```

### Remote Worker Not Reachable

```bash
# Test connectivity
curl -v http://192.168.1.100:8765/health

# Check firewall
sudo ufw status
sudo iptables -L -n | grep 8765

# Verify worker is running (on worker machine)
netstat -tlnp | grep 8765
```

### Fallback to Local Not Working

Ensure the real transcoder exists:

```bash
ls -la "/usr/lib/plexmediaserver/Plex Transcoder.real"
file "/usr/lib/plexmediaserver/Plex Transcoder.real"
# Should be: ELF 64-bit executable
```

### Plex Update Broke Cartridge

The watchdog should auto-repair within 30 seconds. If not:

```bash
# Check watchdog status
sudo systemctl status plex-cartridge-watchdog

# Manual repair
sudo /opt/plex-cartridge/watchdog.sh --once

# Full reinstall
sudo /opt/plex-cartridge/install.sh --worker http://192.168.1.100:8765
```

## Uninstalling

```bash
# Remove cartridge, keep logs
sudo /opt/plex-cartridge/uninstall.sh

# Remove everything
sudo /opt/plex-cartridge/uninstall.sh --purge
```

## Docker/LXC Considerations

### Docker

Mount the cartridge into your Plex container:

```yaml
volumes:
  - ./cartridge:/opt/plex-cartridge
  - ./logs:/var/log/plex-cartridge
```

Run installer inside container:

```bash
docker exec -it plex bash
cd /opt/plex-cartridge
./install.sh --worker http://host.docker.internal:8765
```

### LXC (Proxmox)

Install directly in the container:

```bash
pct exec 106 -- bash -c 'cd /tmp && git clone ... && cd plexbeam/cartridge && ./install.sh'
```

Ensure container has network access to worker.

## Security Notes

1. **Network Isolation:** Ideally, worker only accepts connections from Plex server
2. **API Key:** Use `--api-key` for authentication
3. **Firewall:** Only open port 8765 to Plex server IP

```bash
# On worker machine
sudo ufw allow from 192.168.1.50 to any port 8765
```

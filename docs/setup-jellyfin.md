# Jellyfin Setup Guide

PlexBeam works with Jellyfin out of the box. Jellyfin is simpler than Plex -- it calls standard ffmpeg directly, so no binary replacement or watchdog is needed.

## How It Works

1. PlexBeam installs a shim script that replaces Jellyfin's ffmpeg path
2. When Jellyfin transcodes, the shim intercepts the call
3. The shim dispatches the job to your remote GPU worker
4. If the worker is down, the shim falls back to the real ffmpeg locally

Unlike Plex, Jellyfin sends standard ffmpeg arguments -- no quirky codec names or custom flags to filter.

## Option A: Docker (Recommended)

### 1. Configure environment

```bash
cp .env.example .env
```

Edit `.env`:
```ini
PLEXBEAM_WORKER_URL=http://host.docker.internal:8765  # or worker IP
PLEXBEAM_API_KEY=your-secret  # optional
MEDIA_PATH=C:/Users/you/media  # or /mnt/media on Linux
JELLYFIN_CONFIG_PATH=./config/jellyfin
```

### 2. Start Jellyfin

```bash
docker compose up -d jellyfin
```

The container automatically:
1. Finds `jellyfin-ffmpeg` at `/usr/lib/jellyfin-ffmpeg/ffmpeg`
2. Bakes the cartridge shim with your worker URL
3. Creates/updates `encoding.xml` to point at the shim
4. Creates log directory at `/var/log/plexbeam/`

### 3. Start a GPU worker

```bash
# NVIDIA (Linux Docker)
docker compose --profile nvidia up -d

# Intel QSV (Linux Docker)
docker compose --profile intel up -d

# Bare-metal worker (Windows/Linux)
cd worker
pip install -r requirements.txt
python worker.py
```

### 4. Play something

Open Jellyfin, play a video that requires transcoding. Check the worker:
```bash
curl http://localhost:8765/health
curl http://localhost:8765/jobs
```

## Option B: Bare-Metal (Linux)

### 1. Install

```bash
cd cartridge
sudo ./install.sh --server jellyfin --worker http://YOUR_GPU_PC:8765
```

The installer:
1. Auto-detects Jellyfin ffmpeg at `/usr/lib/jellyfin-ffmpeg/ffmpeg`
2. Creates a shim at `/opt/plexbeam/cartridge-active.sh`
3. Updates `encoding.xml` (if found) to point at the shim
4. No watchdog installed (not needed for Jellyfin)

### 2. Manual encoding.xml setup (if needed)

If the installer couldn't find `encoding.xml`, set the ffmpeg path manually:

1. Open Jellyfin Dashboard
2. Go to **Playback** settings
3. Set **FFmpeg path** to: `/opt/plexbeam/cartridge-active.sh`
4. Save

### 3. Verify

```bash
# Check shim is in place
cat /opt/plexbeam/cartridge-active.sh | head -5
# Should show: PLEXBEAM CARTRIDGE

# Check logs after playing something
tail -f /var/log/plexbeam/master.log
```

## Uninstalling

### Docker
Just stop and remove the container. No cleanup needed.

### Bare-Metal
```bash
sudo /opt/plexbeam/uninstall.sh
```

This restores `encoding.xml` to point back at the original ffmpeg.

## Differences from Plex Setup

| Feature | Plex | Jellyfin |
|---------|------|----------|
| Installation | Replaces binary | Shim script + encoding.xml |
| Watchdog | Required (Plex updates overwrite) | Not needed |
| Arg filtering | Heavy (aac_lc, ochl, -time_delta, etc.) | None (standard ffmpeg) |
| Cartridge home | `/opt/plex-cartridge/` | `/opt/plexbeam/` |
| Log directory | `/var/log/plex-cartridge/` | `/var/log/plexbeam/` |
| Local fallback | QSV rewrite pipeline | Exec real ffmpeg directly |

## Troubleshooting

### Jellyfin can't find the shim
Make sure `encoding.xml` has the correct path:
```xml
<EncoderAppPath>/opt/plexbeam/cartridge-active.sh</EncoderAppPath>
```

### Worker not receiving jobs
Check the cartridge logs:
```bash
tail -f /var/log/plexbeam/cartridge_events.log
```

### Transcoding works locally but not remotely
The worker needs access to the same media files. Configure media path mapping in the worker's `.env`:
```ini
PLEX_WORKER_MEDIA_PATH_FROM=/media
PLEX_WORKER_MEDIA_PATH_TO=/path/to/media/on/worker
```

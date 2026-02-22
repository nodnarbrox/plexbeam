```
     ____  _           ____
    / __ \| |         |  _ \
   | |  | | | _____  _| |_) | ___  __ _ _ __ ___
   | |__| | |/ _ \ \/ /  _ < / _ \/ _` | '_ ` _ \
   |  ____/| |  __/>  <| |_) |  __/ (_| | | | | | |
   |_|     |_|\___/_/\_\____/ \___|\__,_|_| |_| |_|

   Beam your transcodes to a remote GPU

   ┌──────────────┐        HTTP          ┌──────────────┐
   │ PLEX or      │  ════════════════>   │  GPU WORKER  │
   │ JELLYFIN     │  <════════════════   │  Intel QSV   │
   │   SERVER     │   transcoded stream  │  NVIDIA NVENC│
   └──────────────┘                      └──────────────┘
```

# PlexBeam

**Remote GPU transcoding for Plex and Jellyfin** -- beam your transcode jobs from your media server to a dedicated GPU worker over your LAN.

A modern revival of the legendary [plex-remote-transcoder](https://github.com/wnielson/plex-remote-transcoder), completely rewritten from scratch with a new architecture:

- **Plex + Jellyfin** -- one cartridge system that works with both media servers
- **HTTP API** instead of SSH tunnels
- **Streaming transcode** -- pipes output directly back, no shared filesystem required
- **Self-healing cartridge** -- survives Plex updates automatically via watchdog daemon
- **Hardware acceleration** -- Intel QSV, NVIDIA NVENC, VAAPI with full GPU pipeline (HW decode + GPU scale + HW encode)
- **Blazing fast** -- 4K HEVC → 1080p H.264 at **11x realtime** (267 FPS) on Intel Iris Xe via QSV
- **Smart filter conversion** -- automatically converts Jellyfin's software video filters to GPU equivalents (`scale` → `scale_qsv`/`scale_cuda`)
- **Docker or bare-metal** -- run in Docker with the cartridge pre-installed, or install on bare metal
- **Cross-platform worker** -- runs on Windows or Linux
- **Automatic fallback** -- gracefully falls back to local transcoding if the worker is down
- **Orphan job reaper** -- detects and kills stale ffmpeg processes when clients disconnect

## 🚀 Managed Cloud Service — Pre-Beta Signup

**Don't want to manage any of this yourself?** We're launching **[BeamStreams](https://plexbeam.com)** — a fully managed service that handles everything for you.

### GPU Transcoding Workers
- Dedicated RTX 4090 GPU workers, fully managed
- Works with **Plex and Jellyfin** — install the cartridge, point it at your worker URL, done
- From **$19/month** for 1 concurrent transcode
- **50% off** for early adopters during pre-beta

### Turnkey Plex Setups with Infinite Storage
- **Pre-configured Plex server** — we set it up, you just log in and watch
- **Infinite storage** — backed by cloud storage solutions with petabytes of capacity, no drive to fill up, no NAS to maintain
- Access any content without storing anything locally
- GPU transcoding included — 4K on any device, any connection speed

> **[Join the pre-beta waitlist at plexbeam.com →](https://plexbeam.com#waitlist)**

---

## How It Works

```
Plex mode:                              Jellyfin mode:
1. You press Play in Plex               1. You press Play in Jellyfin
           |                                        |
2. Plex calls "Plex Transcoder"         2. Jellyfin calls ffmpeg (our shim)
           |                                        |
3. PlexBeam intercepts (IS the binary)  3. PlexBeam intercepts the call
           |                                        |
4. Dispatches to GPU worker via HTTP    4. Dispatches to GPU worker via HTTP
           |                                        |
5. Worker filters Plex quirks + encodes 5. Worker passes through clean args
           |                                        |
6. Transcoded stream pipes back         6. Transcoded stream pipes back
           |                                        |
7. You're watching -- remote GPU!       7. You're watching -- remote GPU!
```

## Quick Start

### Option A: Docker (Plex or Jellyfin + Cartridge)

```bash
# Copy and configure .env
cp .env.example .env
# Edit .env with your settings (worker URL, media path, etc.)

# Start your media server with cartridge pre-installed:
docker compose up -d plex       # Plex
docker compose up -d jellyfin   # Jellyfin
docker compose up -d plex jellyfin  # Both

# Start GPU worker (pick one):
docker compose --profile nvidia up -d   # NVIDIA GPU (Linux)
docker compose --profile intel up -d    # Intel QSV (Linux)
```

> **Windows Docker note:** Intel GPU Docker workers do NOT work on Windows (WSL2 lacks i915/KMS). On Windows, run the worker bare-metal instead (see Option B below).

### Option B: Bare-Metal Worker (Windows/Linux)

```bash
cd worker
pip install -r requirements.txt

# Create .env
cat > .env << 'EOF'
PLEX_WORKER_HW_ACCEL=qsv
PLEX_WORKER_HOST=0.0.0.0
PLEX_WORKER_PORT=8765
EOF

python worker.py
```

If your Plex runs in Docker but the worker runs bare-metal, add media path mapping so the worker can find files:

```ini
# Maps Docker container paths to host paths
PLEX_WORKER_MEDIA_PATH_FROM=/media
PLEX_WORKER_MEDIA_PATH_TO=C:/Users/you/media
```

### Option C: Bare-Metal Cartridge (Linux Server)

```bash
cd cartridge

# Plex (auto-detected)
sudo ./install.sh --worker http://YOUR_GPU_PC:8765

# Jellyfin (auto-detected, or explicit)
sudo ./install.sh --server jellyfin --worker http://YOUR_GPU_PC:8765
```

### Play Something

Hit play on a video that needs transcoding. Check the worker:

```bash
curl http://localhost:8765/health    # Should show hw_accel: "qsv"
curl http://localhost:8765/jobs      # Shows active transcode jobs
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│            PLEX or JELLYFIN SERVER (Docker or Linux)              |
│                                                                  |
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  CARTRIDGE                                                 │  │
│  │  Plex: replaces "Plex Transcoder" binary                   │  │
│  │  Jellyfin: shim script pointed to by encoding.xml          │  │
│  │  * Intercepts all transcode requests                       │  │
│  │  * Dispatches to remote GPU via HTTP                       │  │
│  │  * Falls back to local if worker unavailable               │  │
│  └────────────────────────────────────────────────────────────┘  │
│                           |                                      │
│                    HTTP POST /transcode/stream                   │
└───────────────────────────|──────────────────────────────────────┘
                            |
                       Your LAN
                            |
┌───────────────────────────v──────────────────────────────────────┐
│              GPU WORKER (Windows/Linux, Docker or bare-metal)     │
│                                                                   │
│  FastAPI service + FFmpeg with hardware acceleration              │
│  * Plex args: strips quirks, replaces encoder, injects hwaccel   │
│  * Jellyfin args: converts SW filters to GPU, injects hwaccel    │
│  * Orphan reaper kills stale jobs on client disconnect            │
│  Intel QSV | NVIDIA NVENC | VAAPI                                 │
└───────────────────────────────────────────────────────────────────┘
```

## Docker Deployment

The Docker setup uses [linuxserver/plex](https://github.com/linuxserver/docker-plex) and [linuxserver/jellyfin](https://github.com/linuxserver/docker-jellyfin) as base images with the PlexBeam cartridge pre-installed via S6 overlay init scripts.

```bash
# Plex only (worker runs elsewhere)
docker compose up -d plex

# Jellyfin only
docker compose up -d jellyfin

# Full stack with NVIDIA worker
docker compose --profile nvidia up -d

# Full stack with Intel QSV worker (Linux only)
docker compose --profile intel up -d
```

**Plex container:** Backs up the real transcoder binary, installs cartridge in its place, runs a watchdog that re-installs after Plex updates.

**Jellyfin container:** Installs a shim script and configures `encoding.xml` to point at it. No watchdog needed -- Jellyfin doesn't overwrite the ffmpeg binary.

### Docker + Bare-Metal Worker (Windows)

For Windows users with Intel iGPU:

1. Run Plex in Docker: `docker compose up -d plex`
2. Set `PLEXBEAM_WORKER_URL=http://host.docker.internal:8765` in `.env`
3. Run the worker bare-metal: `cd worker && python worker.py`
4. Configure media path mapping in `worker/.env` so the worker can resolve Docker paths

## What Changed From The Original

The original [plex-remote-transcoder](https://github.com/wnielson/plex-remote-transcoder) by wnielson was a pioneering project that proved remote Plex transcoding was possible. It hasn't been updated in years and relied on SSH tunnels and Python monkey-patching.

**PlexBeam** is a ground-up rewrite with a completely different approach:

| Feature | Original (plex-remote-transcoder) | PlexBeam |
|---------|-----------------------------------|----------|
| Transport | SSH tunnels | HTTP API |
| Output | Shared filesystem required | Streams directly back via pipe |
| Installation | Python package + monkey-patch | Shell script cartridge |
| Plex Updates | Broke on every update | Self-healing watchdog daemon |
| Hardware Accel | Software only | QSV, NVENC, VAAPI |
| Worker Platform | Linux only | Windows + Linux |
| Deployment | Manual only | Docker Compose or bare-metal |
| Language | Python (Plex server) | Bash cartridge + Python worker |
| Status | Unmaintained since ~2020 | Active |

## Requirements

### Plex Server (Docker or Linux)
- Plex Media Server
- Root/sudo access (bare-metal) or Docker
- `curl` installed
- Network access to worker

### GPU Worker (Windows/Linux)
- Python 3.10+
- FFmpeg with hardware encoding support
- Intel QSV (6th gen+ CPU) OR NVIDIA NVENC (GTX 900+)

## Configuration

### Worker `.env`

```ini
PLEX_WORKER_PORT=8765
PLEX_WORKER_HW_ACCEL=qsv          # qsv, nvenc, vaapi, or none
PLEX_WORKER_HOST=0.0.0.0
PLEX_WORKER_MAX_CONCURRENT_JOBS=2
PLEX_WORKER_API_KEY=your-secret    # optional auth

# Media path mapping (when Plex runs in Docker, worker runs bare-metal)
PLEX_WORKER_MEDIA_PATH_FROM=/media
PLEX_WORKER_MEDIA_PATH_TO=C:/Users/you/media

# Multiple path mappings for Plex + Jellyfin on the same worker
# Semicolon-delimited from=to pairs (longest prefix wins)
PLEX_WORKER_PATH_MAPPINGS=/config/Library=C:/path/to/plex/Library;/config/cache=C:/path/to/jellyfin/cache;/config/data=C:/path/to/jellyfin/data
```

### Docker `.env` (project root)

See `.env.example` for all available variables:

```ini
PLEXBEAM_WORKER_URL=http://host.docker.internal:8765
PLEXBEAM_API_KEY=your-secret
MEDIA_PATH=C:/Users/you/media
PLEX_CONFIG_PATH=./config/plex
```

### Cartridge Installation (bare-metal)

```bash
# Plex (auto-detected)
sudo ./install.sh --worker http://GPU_PC:8765

# Jellyfin (auto-detected, or explicit)
sudo ./install.sh --server jellyfin --worker http://GPU_PC:8765

# With auth
sudo ./install.sh --worker http://GPU_PC:8765 --api-key your-secret

# With auto-updates from GitHub
sudo ./install.sh --worker http://GPU_PC:8765 --repo https://github.com/nodnarbrox/plexbeam
```

## Commands

### On Plex Server

```bash
# View transcode summary
sudo /opt/plex-cartridge/analyze.sh

# Check remote feasibility
sudo /opt/plex-cartridge/analyze.sh --remote-feasibility

# Health check
sudo /opt/plex-cartridge/watchdog.sh --once

# View logs
tail -f /var/log/plex-cartridge/master.log

# Uninstall
sudo /opt/plex-cartridge/uninstall.sh
```

### On GPU Worker

```bash
python worker.py                          # Start worker
curl http://localhost:8765/health          # Health check
curl http://localhost:8765/jobs            # List active jobs
```

## Performance

Full GPU pipeline: hardware decode + GPU scaling + hardware encode.

| Source | Content | GPU | Speed | Notes |
|--------|---------|-----|-------|-------|
| Plex | 4K HEVC → 1080p H.264 | Intel Iris Xe (QSV) | **11x** (267 FPS) | VDBOX fixed-function encode |
| Jellyfin | 4K HEVC → 1080p H.264 | Intel Iris Xe (QSV) | **8-17x** | SW filter auto-converted to `scale_qsv` |
| Plex | 4K HEVC → 1080p H.264 | NVIDIA (NVENC) | TBD | P1 preset, ultra-low latency tune |

Key speed flags applied automatically:
- **QSV**: `-low_power 1` (VDBOX), `-async_depth 1`, `-preset veryfast`, `-global_quality 25`
- **NVENC**: `-preset p1`, `-tune ull`, `-cq 25`
- **All**: Hardware decode (`-hwaccel qsv/cuda`) with `-hwaccel_output_format` for zero-copy pipeline

## Supported Hardware

| GPU | Encoder | Platform | Notes |
|-----|---------|----------|-------|
| Intel QSV (6th gen+) | h264_qsv, hevc_qsv | Windows/Linux | Bare-metal on Windows, Docker on Linux |
| NVIDIA GTX 900+ | h264_nvenc, hevc_nvenc | Windows/Linux | 3-5 concurrent streams (consumer) |
| NVIDIA RTX/Quadro/Tesla | h264_nvenc, hevc_nvenc | Windows/Linux | Unlimited streams |
| AMD/Intel VAAPI | h264_vaapi | Linux only | Docker or bare-metal |

> **Windows note:** Intel QSV works great bare-metal on Windows with full HW decode+encode pipeline. Intel GPU Docker workers do not work on Windows due to WSL2 lacking i915/KMS drivers.

## Project Structure

```
plexbeam/
├── docker-compose.yml         # Full-stack Docker Compose (Plex + Jellyfin + workers)
├── .env.example               # Environment variable template
├── cartridge/                 # Media server component (Plex + Jellyfin)
│   ├── cartridge.sh           # Universal interceptor script (Plex + Jellyfin)
│   ├── Dockerfile             # Plex Docker image (linuxserver/plex + cartridge)
│   ├── Dockerfile.jellyfin    # Jellyfin Docker image (linuxserver/jellyfin + cartridge)
│   ├── docker-init.sh         # Plex S6 init script
│   ├── docker-init-jellyfin.sh # Jellyfin S6 init script
│   ├── docker-watchdog.sh     # S6 service (Plex only)
│   ├── watchdog.sh            # Self-healing daemon (Plex only)
│   ├── install.sh             # Bare-metal installer (--server plex|jellyfin)
│   ├── uninstall.sh           # Clean removal
│   └── analyze.sh             # Session analyzer
├── worker/                    # GPU worker (Windows/Linux)
│   ├── Dockerfile.nvidia      # NVIDIA NVENC Docker image
│   ├── Dockerfile.intel       # Intel QSV Docker image (Linux)
│   ├── worker.py              # FastAPI service (routes Plex/Jellyfin args)
│   ├── transcoder.py          # FFmpeg wrapper with HW accel + source routing
│   ├── config.py              # Pydantic settings
│   └── requirements.txt       # Python dependencies
├── protocol/                  # Shared definitions
│   └── job_schema.json        # Job format spec
└── docs/                      # Guides
    ├── architecture.md
    ├── setup-linux.md
    ├── setup-windows.md
    └── setup-jellyfin.md
```

## Documentation

- [Architecture Overview](docs/architecture.md)
- [Linux Plex Server Setup](docs/setup-linux.md)
- [Jellyfin Setup](docs/setup-jellyfin.md)
- [Windows GPU Worker Setup](docs/setup-windows.md)

## Credits

Inspired by [plex-remote-transcoder](https://github.com/wnielson/plex-remote-transcoder) by wnielson. That project proved the concept; PlexBeam reimagines it for modern setups with HTTP streaming, hardware acceleration, and self-healing installation.

## License

MIT

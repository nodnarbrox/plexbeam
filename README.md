```
     ____  _           ____
    / __ \| |         |  _ \
   | |  | | | _____  _| |_) | ___  __ _ _ __ ___
   | |__| | |/ _ \ \/ /  _ < / _ \/ _` | '_ ` _ \
   |  ____/| |  __/>  <| |_) |  __/ (_| | | | | | |
   |_|     |_|\___/_/\_\____/ \___|\__,_|_| |_| |_|

   Beam your transcodes to a remote GPU

   ┌──────────┐          HTTP           ┌──────────────┐
   │   PLEX   │  ════════════════════>  │  GPU WORKER  │
   │  SERVER  │  <════════════════════  │  Intel QSV   │
   │          │    transcoded stream    │  NVIDIA NVENC│
   └──────────┘                         └──────────────┘
```

# PlexBeam

**Remote GPU transcoding for Plex** -- beam your transcode jobs from a Plex server to a dedicated GPU worker over your LAN.

A modern revival of the legendary [plex-remote-transcoder](https://github.com/wnielson/plex-remote-transcoder), completely rewritten from scratch with a new architecture:

- **HTTP API** instead of SSH tunnels
- **Streaming transcode** -- pipes output directly back to Plex, no shared filesystem required
- **Self-healing cartridge** -- survives Plex updates automatically via watchdog daemon
- **Hardware acceleration** -- Intel QSV, NVIDIA NVENC, VAAPI
- **Docker or bare-metal** -- run Plex in Docker with the cartridge pre-installed, or install on bare metal
- **Cross-platform worker** -- runs on Windows or Linux
- **Automatic fallback** -- gracefully falls back to local transcoding if the worker is down

## How It Works

```
1. You press Play in Plex
            |
2. Plex calls its "Plex Transcoder" binary
            |
3. PlexBeam intercepts the call (it IS the binary)
            |
4. Dispatches the job to your GPU worker via HTTP
            |
5. Worker runs FFmpeg with QSV/NVENC hardware encoding
            |
6. Transcoded stream pipes back to Plex
            |
7. You're watching -- powered by a remote GPU
```

## Quick Start

### Option A: Docker (Plex + Cartridge)

```bash
# Copy and configure .env
cp .env.example .env
# Edit .env with your settings (worker URL, media path, etc.)

# Start Plex with cartridge pre-installed
docker compose up -d plex

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

### Option C: Bare-Metal Cartridge (Linux Plex Server)

```bash
cd cartridge
sudo ./install.sh --worker http://YOUR_GPU_PC:8765
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
│                    PLEX SERVER (Docker or Linux)                  |
│                                                                  |
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  CARTRIDGE (replaces "Plex Transcoder")                    │  │
│  │  * Intercepts all transcode requests                       │  │
│  │  * Self-heals after Plex updates (watchdog)                │  │
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
│  Intel QSV | NVIDIA NVENC | VAAPI                                 │
└───────────────────────────────────────────────────────────────────┘
```

## Docker Deployment

The Docker setup uses [linuxserver/plex](https://github.com/linuxserver/docker-plex) as the base image with the PlexBeam cartridge pre-installed via S6 overlay init scripts.

```bash
# Plex only (worker runs elsewhere)
docker compose up -d plex

# Full stack with NVIDIA worker
docker compose --profile nvidia up -d

# Full stack with Intel QSV worker (Linux only)
docker compose --profile intel up -d
```

The Plex container automatically:
1. Backs up the real Plex Transcoder binary
2. Installs the PlexBeam cartridge in its place
3. Runs a watchdog that re-installs after Plex updates

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
# Basic
sudo ./install.sh --worker http://GPU_PC:8765

# With auth
sudo ./install.sh --worker http://GPU_PC:8765 --api-key your-secret

# With auto-updates from GitHub
sudo ./install.sh --worker http://GPU_PC:8765 --repo https://github.com/you/plexbeam
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

## Supported Hardware

| GPU | Encoder | Platform | Notes |
|-----|---------|----------|-------|
| Intel QSV (6th gen+) | h264_qsv, hevc_qsv | Windows/Linux | Bare-metal on Windows, Docker on Linux |
| NVIDIA GTX 900+ | h264_nvenc, hevc_nvenc | Windows/Linux | 3-5 concurrent streams (consumer) |
| NVIDIA RTX/Quadro | h264_nvenc, hevc_nvenc | Windows/Linux | Unlimited streams |
| AMD/Intel VAAPI | h264_vaapi | Linux only | Docker or bare-metal |

> **Windows note:** Intel QSV works great bare-metal on Windows (software decode + QSV encode). Intel GPU Docker workers do not work on Windows due to WSL2 lacking i915/KMS drivers.

## Project Structure

```
plexbeam/
├── docker-compose.yml         # Full-stack Docker Compose
├── .env.example               # Environment variable template
├── cartridge/                 # Plex server component
│   ├── Dockerfile             # Docker image (linuxserver/plex + cartridge)
│   ├── docker-init.sh         # S6 init script (installs cartridge on boot)
│   ├── docker-watchdog.sh     # S6 service (re-installs after Plex updates)
│   ├── plex_cartridge.sh      # The interceptor script
│   ├── watchdog.sh            # Self-healing daemon
│   ├── install.sh             # Bare-metal installer
│   ├── uninstall.sh           # Clean removal
│   └── analyze.sh             # Session analyzer
├── worker/                    # GPU worker (Windows/Linux)
│   ├── Dockerfile.nvidia      # NVIDIA NVENC Docker image
│   ├── Dockerfile.intel       # Intel QSV Docker image (Linux)
│   ├── worker.py              # FastAPI service
│   ├── transcoder.py          # FFmpeg wrapper with HW accel
│   ├── config.py              # Pydantic settings
│   └── requirements.txt       # Python dependencies
├── protocol/                  # Shared definitions
│   └── job_schema.json        # Job format spec
└── docs/                      # Guides
    ├── architecture.md
    ├── setup-linux.md
    └── setup-windows.md
```

## Documentation

- [Architecture Overview](docs/architecture.md)
- [Linux Plex Server Setup](docs/setup-linux.md)
- [Windows GPU Worker Setup](docs/setup-windows.md)

## Credits

Inspired by [plex-remote-transcoder](https://github.com/wnielson/plex-remote-transcoder) by wnielson. That project proved the concept; PlexBeam reimagines it for modern setups with HTTP streaming, hardware acceleration, and self-healing installation.

## License

MIT

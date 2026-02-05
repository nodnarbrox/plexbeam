```
     ____  _           ____
    / __ \| |         |  _ \
   | |  | | | _____  _| |_) | ___  __ _ _ __ ___
   | |__| | |/ _ \ \/ /  _ < / _ \/ _` | '_ ` _ \
   |  ____/| |  __/>  <| |_) |  __/ (_| | | | | | |
   |_|     |_|\___/_/\_\____/ \___|\__,_|_| |_| |_|

   ⚡ Beam your transcodes to a remote GPU ⚡

   ┌──────────┐          HTTP           ┌──────────────┐
   │   PLEX   │  ════════════════════>  │  GPU WORKER  │
   │  SERVER  │  <════════════════════  │  Intel QSV   │
   │ (Linux)  │    transcoded stream    │  NVIDIA NVENC│
   └──────────┘                         └──────────────┘
```

# PlexBeam

**Remote GPU transcoding for Plex** -- beam your transcode jobs from a Linux Plex server to a dedicated GPU worker over your LAN.

A modern revival of the legendary [plex-remote-transcoder](https://github.com/wnielson/plex-remote-transcoder), completely rewritten from scratch with a new architecture:

- **HTTP API** instead of SSH tunnels
- **Streaming transcode** -- pipes output directly back to Plex, no shared filesystem required
- **Self-healing cartridge** -- survives Plex updates automatically via watchdog daemon
- **Hardware acceleration** -- Intel QSV, NVIDIA NVENC, VAAPI
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

### 1. GPU Worker (Windows/Linux)

```powershell
cd worker
pip install -r requirements.txt

# Create .env with your GPU type
echo PLEX_WORKER_HW_ACCEL=qsv > .env

python worker.py
```

### 2. Cartridge (Linux Plex Server)

```bash
cd cartridge
sudo ./install.sh --worker http://YOUR_GPU_PC:8765
```

### 3. Play Something

Hit play on a video that needs transcoding. Watch the worker handle it.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    PLEX SERVER (Linux)                          |
│                                                                |
│  ┌────────────────────────────────────────────────────────────┐│
│  │  CARTRIDGE (replaces "Plex Transcoder")                    ││
│  │  * Intercepts all transcode requests                       ││
│  │  * Self-heals after Plex updates (watchdog)                ││
│  │  * Dispatches to remote GPU via HTTP                       ││
│  │  * Falls back to local if worker unavailable               ││
│  └────────────────────────────────────────────────────────────┘│
│                           |                                    │
│                    HTTP POST /transcode/stream                 │
└───────────────────────────|────────────────────────────────────┘
                            |
                       Your LAN
                            |
┌───────────────────────────v────────────────────────────────────┐
│              GPU WORKER (Windows/Linux)                         │
│                                                                │
│  FastAPI service + FFmpeg with hardware acceleration           │
│  Intel QSV | NVIDIA NVENC | VAAPI                              │
└────────────────────────────────────────────────────────────────┘
```

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
| Language | Python (Plex server) | Bash cartridge + Python worker |
| Status | Unmaintained since ~2020 | Active |

## Requirements

### Plex Server (Linux)
- Plex Media Server
- Root/sudo access
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
PLEX_WORKER_QSV_PRESET=fast
PLEX_WORKER_QSV_QUALITY=23
PLEX_WORKER_MAX_CONCURRENT_JOBS=2
PLEX_WORKER_API_KEY=your-secret    # optional auth
```

### Cartridge Installation

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

| GPU | Encoder | Platform | Concurrent Streams |
|-----|---------|----------|-------------------|
| Intel QSV (6th gen+) | h264_qsv, hevc_qsv | Windows/Linux | Unlimited |
| NVIDIA GTX 900+ | h264_nvenc, hevc_nvenc | Windows/Linux | 3-5 (consumer) |
| NVIDIA RTX/Quadro | h264_nvenc, hevc_nvenc | Windows/Linux | Unlimited |
| AMD/Intel VAAPI | h264_vaapi | Linux | Varies |

## Project Structure

```
plexbeam/
├── cartridge/              # Linux Plex server component
│   ├── plex_cartridge.sh   # The interceptor script
│   ├── watchdog.sh         # Self-healing daemon
│   ├── install.sh          # Installer
│   ├── uninstall.sh        # Clean removal
│   └── analyze.sh          # Session analyzer
├── worker/                 # GPU worker (Windows/Linux)
│   ├── worker.py           # FastAPI service
│   ├── transcoder.py       # FFmpeg wrapper
│   ├── config.py           # Pydantic settings
│   └── requirements.txt    # Python deps
├── protocol/               # Shared definitions
│   └── job_schema.json     # Job format spec
└── docs/                   # Guides
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

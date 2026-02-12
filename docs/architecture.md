# PlexBeam Architecture

## Overview

PlexBeam enables remote GPU transcoding for **Plex and Jellyfin** by intercepting transcode requests and dispatching them to a dedicated GPU worker over HTTP. One unified cartridge system works with both media servers.

## System Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│          PLEX or JELLYFIN SERVER (Docker or Linux)                │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  CARTRIDGE (cartridge.sh)                                  │  │
│  │  Plex:     replaces "Plex Transcoder" binary               │  │
│  │  Jellyfin: shim script in /opt/plexbeam/                   │  │
│  │  - Intercepts all transcode requests                       │  │
│  │  - Dispatches to remote GPU via HTTP API                   │  │
│  │  - Falls back to local if worker unavailable               │  │
│  └────────────────────────────────────────────────────────────┘  │
│                           |                                      │
│                    HTTP POST /transcode/stream                   │
└───────────────────────────|──────────────────────────────────────┘
                            |
                    LAN (e.g., 192.168.x.x)
                            |
┌───────────────────────────v──────────────────────────────────────┐
│            GPU WORKER (Windows/Linux, Docker or bare-metal)       │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  FastAPI Worker Service (port 8765)                        │  │
│  │  - POST /transcode/stream - Streaming transcode            │  │
│  │  - POST /transcode - Queued transcode jobs                 │  │
│  │  - GET /status/{id} - Job progress                         │  │
│  │  - GET /health - Health check                              │  │
│  │  Routes based on "source": Plex=filtered, Jellyfin=clean   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                           |                                      │
│  ┌────────────────────────v───────────────────────────────────┐  │
│  │  FFmpeg with Hardware Acceleration                         │  │
│  │  - Intel QSV (h264_qsv, hevc_qsv)                         │  │
│  │  - NVIDIA NVENC (h264_nvenc, hevc_nvenc)                   │  │
│  │  - VAAPI (Linux only)                                      │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  GPU: Intel QSV / NVIDIA / AMD                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Cartridge (Plex or Jellyfin Server)

**Location:** `/opt/plex-cartridge/` (Plex) or `/opt/plexbeam/` (Jellyfin)

The cartridge (`cartridge.sh`) is a universal shell script with a `SERVER_TYPE` variable that controls behavior:

**Plex mode:** Replaces the `Plex Transcoder` binary. On local fallback, rewrites Plex-specific args (aac_lc, ochl, QSV pipeline).

**Jellyfin mode:** Installed as a shim script; Jellyfin's `encoding.xml` points at it. On local fallback, passes args through unmodified (Jellyfin uses standard ffmpeg).

When a transcode starts:

1. Cartridge intercepts the call with all arguments
2. Checks if the job is a video copy (direct stream) -- if so, runs locally
3. POSTs raw FFmpeg arguments to the remote GPU worker's streaming endpoint
4. Worker receives the `"source"` field ("plex" or "jellyfin") for routing
5. Pipes the transcoded stream back to the media server
6. Falls back to local transcoding if the worker is unreachable

**Key Features:**
- **Self-Healing:** Watchdog daemon monitors for Plex updates (Plex only)
- **Pattern Learning:** Logs unique argument patterns for analysis
- **Streaming:** Pipes output directly back, no shared filesystem needed
- **Fallback:** Gracefully falls back to local transcoding

### 2. GPU Worker (Windows/Linux)

**Location:** Any machine with a GPU

The worker is a Python FastAPI service that routes based on the `source` field:

**Plex source:**
1. Receives raw Plex FFmpeg arguments via HTTP
2. Filters Plex-specific options that standard FFmpeg doesn't understand
3. Replaces `libx264` with hardware encoder (h264_qsv, h264_nvenc, etc.)
4. Applies media path mapping (Docker container paths to host paths)
5. Executes FFmpeg with hardware acceleration
6. Streams output back to the cartridge via HTTP response

**Jellyfin source:**
1. Receives standard FFmpeg arguments via HTTP
2. Applies media path mapping only (args are already clean)
3. Executes FFmpeg with hardware acceleration
4. Streams output back

**Plex FFmpeg Compatibility:**
The worker handles several Plex-specific quirks (skipped for Jellyfin):
- Strips `-loglevel_plex`, `-progressurl`, `-time_delta` and other Plex-only options
- Replaces `aac_lc` codec name with standard `aac`
- Rewrites `ochl` to `ocl` for older FFmpeg versions (<5.0)
- Strips `-preset:0` and `-x264opts` when using hardware encoders
- Strips VAAPI filter_complex and fixes `-map` references

**Supported Hardware:**
- Intel Quick Sync Video (QSV) -- Intel 6th gen+ CPUs
- NVIDIA NVENC -- GTX 900+, RTX series
- VAAPI -- Intel/AMD on Linux

### 3. Watchdog Daemon

**Purpose:** Ensure cartridge survives Plex updates

When Plex updates:
1. Plex installer overwrites the transcoder binary
2. Watchdog detects the binary change (MD5 mismatch)
3. Backs up the new Plex binary as `.real`
4. Reinstalls the cartridge shim from the pre-baked template
5. Logs the version change

**Docker vs Bare-Metal:**
- **Docker:** Runs as an S6 overlay service (`svc-plexbeam-watchdog`)
- **Bare-Metal:** Runs as a systemd service (`plex-cartridge-watchdog.service`)

## Communication Flow

### Streaming Transcode (Primary Mode)

```
1. User starts playback requiring transcode
          |
          v
2. Plex calls "Plex Transcoder" with arguments
          |
          v
3. Cartridge intercepts (it IS the transcoder binary)
          |
          +-- Checks: is this video copy? -> run locally
          +-- Checks: is worker healthy? -> if not, fall back to local
          |
          v
4. POST /transcode/stream with raw FFmpeg args
          |
          v
5. Worker filters args, replaces encoder with HW accel
          |
          v
6. Worker runs FFmpeg, streams output in HTTP response
          |
          v
7. Cartridge pipes stream to Plex's expected output location
          |
          v
8. Plex serves the transcoded stream to the client
```

### Queued Transcode (Alternative Mode)

For jobs that write to shared storage:

```
1. POST /transcode with job JSON
          |
          v
2. Worker queues job, returns job_id
          |
          v
3. Cartridge polls GET /status/{job_id}
          |
          v
4. Worker writes segments to shared storage
          |
          v
5. Plex reads segments from shared path
```

## Docker Template Strategy

The Docker image uses a template system for the cartridge:

```
.orig template (7 placeholders)
    |
    v  docker-init.sh bakes Docker env vars (4 of 7: SERVER_TYPE + 3 env vars)
Pre-baked template (3 path placeholders remain)
    |
    v  docker-init.sh bakes path vars (remaining 3)
Active cartridge (all 7 resolved)
```

When the watchdog reinstalls after a Plex update, it reads the pre-baked template (not the `.orig`), so Docker environment variables (including SERVER_TYPE) survive the reinstall.

**Jellyfin Docker:** Uses `docker-init-jellyfin.sh` which bakes all 7 placeholders at once into a shim at `/opt/plexbeam/cartridge-active.sh`. No watchdog needed.

## Hardware Acceleration

### Intel QSV (Windows Bare-Metal)

On Windows, QSV uses software decode + QSV encode (no hwaccel decode flags needed):

```bash
ffmpeg -i input.mkv \
  -c:v h264_qsv -preset veryfast -global_quality 26 \
  -vf scale=1920:-2 \
  -c:a aac -b:a 128k \
  output.mp4
```

### Intel QSV (Linux Docker)

```bash
ffmpeg -hwaccel qsv -hwaccel_output_format qsv \
  -i input.mkv \
  -c:v h264_qsv -preset fast -global_quality 23 \
  -c:a aac -b:a 128k \
  output.mp4
```

### NVIDIA NVENC

```bash
ffmpeg -hwaccel cuda \
  -i input.mkv \
  -c:v h264_nvenc -preset p4 -cq 23 \
  -c:a aac -b:a 128k \
  output.mp4
```

Requirements:
- NVIDIA GTX 900+, RTX, or Quadro
- NVIDIA drivers with NVENC support
- Windows/Linux

## Fallback Strategy

```
+-------------------------------------+
| Try remote worker                   |
|                                     |
| +- Health check GET /health ------+ |
| |                                 | |
| |  Success? --> Dispatch job      | |
| |  Failure? --> Fall back         | |
| +---------------------------------+ |
|                                     |
| +- If remote fails ---------------+ |
| |                                 | |
| |  FALLBACK_TO_LOCAL=true?        | |
| |  Yes --> Run local transcoder   | |
| |  No  --> Exit with error        | |
| +---------------------------------+ |
+-------------------------------------+
```

## Docker Deployment

PlexBeam uses [linuxserver/plex](https://github.com/linuxserver/docker-plex) and [linuxserver/jellyfin](https://github.com/linuxserver/docker-jellyfin) as base images with S6 overlay v3 for service management.

```yaml
# docker-compose.yml
services:
  plex:
    build: ./cartridge        # linuxserver/plex + cartridge
    environment:
      - PLEXBEAM_WORKER_URL=http://worker:8765

  jellyfin:
    build:
      context: ./cartridge
      dockerfile: Dockerfile.jellyfin  # linuxserver/jellyfin + cartridge
    environment:
      - PLEXBEAM_WORKER_URL=http://worker:8765

  worker-nvidia:
    profiles: [nvidia]
    # NVIDIA GPU

  worker-intel:
    profiles: [intel]
    # Intel QSV (Linux only, requires /dev/dri)
```

**Windows Docker + Bare-Metal Worker:**

Intel GPU Docker workers do not work on Windows (WSL2 lacks i915/KMS). Instead, run Plex in Docker and the worker bare-metal:

```
Plex Docker --> http://host.docker.internal:8765 --> Bare-metal worker (QSV)
```

## Security Considerations

1. **API Key Authentication:** Worker can require X-API-Key header
2. **Network Isolation:** Worker should only be accessible from Plex server
3. **Input Validation:** Worker validates job requests
4. **Resource Limits:** Max concurrent jobs, timeouts

## Monitoring

### Logs

- `/var/log/plex-cartridge/master.log` -- One line per transcode
- `/var/log/plex-cartridge/cartridge_events.log` -- Events, errors, updates
- `/var/log/plex-cartridge/sessions/` -- Full session details

### Analysis

```bash
# View transcode summary
sudo /opt/plex-cartridge/analyze.sh

# Check remote feasibility
sudo /opt/plex-cartridge/analyze.sh --remote-feasibility

# View specific session
sudo /opt/plex-cartridge/analyze.sh --detail 20250205_143022_12345
```

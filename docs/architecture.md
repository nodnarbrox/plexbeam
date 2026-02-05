# PlexBeam Architecture

## Overview

PlexBeam enables remote GPU transcoding for Plex by intercepting transcode requests and dispatching them to a dedicated GPU worker over HTTP.

## System Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    PLEX SERVER (Linux)                          │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  CARTRIDGE (replaces "Plex Transcoder")                    │ │
│  │  • Intercepts all transcode requests                       │ │
│  │  • Self-heals after Plex updates (watchdog)                │ │
│  │  • Learns argument patterns                                │ │
│  │  • Dispatches to remote GPU via HTTP API                   │ │
│  │  • Falls back to local if worker unavailable               │ │
│  └────────────────────────────────────────────────────────────┘ │
│                           │                                      │
│                    HTTP POST /transcode                          │
└───────────────────────────┼─────────────────────────────────────┘
                            │
                    LAN (e.g., 192.168.x.x)
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│              GPU WORKER (Windows/Linux)                          │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  FastAPI Worker Service (port 8765)                        │ │
│  │  • POST /transcode - Receive jobs                          │ │
│  │  • GET /status/{id} - Job progress                         │ │
│  │  • WS /ws/progress - Real-time updates                     │ │
│  └────────────────────────────────────────────────────────────┘ │
│                           │                                      │
│  ┌────────────────────────▼───────────────────────────────────┐ │
│  │  FFmpeg with Hardware Acceleration                         │ │
│  │  • Intel QSV (h264_qsv, hevc_qsv)                          │ │
│  │  • NVIDIA NVENC (h264_nvenc, hevc_nvenc)                   │ │
│  │  • VAAPI (Linux)                                           │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  GPU: Intel QSV / NVIDIA / AMD                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Cartridge (Linux - Plex Server)

**Location:** `/opt/plex-cartridge/`

The cartridge is a shell script that replaces Plex's `Plex Transcoder` binary. When Plex initiates a transcode:

1. Cartridge intercepts the call with all arguments
2. Parses arguments to extract: input file, codecs, bitrate, resolution, etc.
3. Creates a JSON job request
4. POSTs to the remote GPU worker
5. Polls for completion
6. Falls back to local transcoding if worker fails

**Key Features:**
- **Self-Healing:** Watchdog daemon monitors for Plex updates and reinstalls cartridge
- **Pattern Learning:** Logs unique argument patterns for analysis
- **Fallback:** Gracefully falls back to local transcoding

### 2. GPU Worker (Windows/Linux)

**Location:** Any machine with a GPU

The worker is a Python FastAPI service that:

1. Receives transcode job requests via HTTP
2. Maps Plex arguments to FFmpeg with hardware acceleration
3. Executes transcoding with QSV/NVENC/VAAPI
4. Reports progress via polling or WebSocket
5. Writes output to shared storage or streams back

**Supported Hardware:**
- Intel Quick Sync Video (QSV) - Intel 6th gen+ CPUs
- NVIDIA NVENC - GTX 900+, RTX series
- VAAPI - Intel/AMD on Linux

### 3. Watchdog Daemon

**Purpose:** Ensure cartridge survives Plex updates

When Plex updates:
1. Plex installer overwrites the transcoder binary
2. Watchdog detects the binary change (MD5 mismatch)
3. Backs up the new Plex binary as `.real`
4. Reinstalls the cartridge shim
5. Logs the version change

## Communication Flow

### Transcode Request Flow

```
1. User starts playback requiring transcode
          │
          ▼
2. Plex calls "Plex Transcoder" with arguments
          │
          ▼
3. Cartridge intercepts (it IS the transcoder binary)
          │
          ├── Parse arguments
          ├── Build JSON job
          │
          ▼
4. POST /transcode → GPU Worker
          │
          ├── Worker queues job
          ├── FFmpeg runs with QSV/NVENC
          │
          ▼
5. Cartridge polls GET /status/{job_id}
          │
          ├── Progress updates
          ├── Until: completed/failed
          │
          ▼
6. Worker writes segments to shared storage
          │
          ▼
7. Plex reads segments, streams to client
```

### Job JSON Structure

```json
{
  "job_id": "20250205_143022_12345",
  "input": {
    "type": "file",
    "path": "/srv/media/movie.mkv"
  },
  "output": {
    "type": "hls",
    "path": "/transcode/sessions/abc123",
    "segment_duration": 4
  },
  "arguments": {
    "video_codec": "h264",
    "audio_codec": "aac",
    "video_bitrate": "4M",
    "resolution": "1920x1080",
    "hw_accel": "qsv"
  }
}
```

## Media Access Strategies

### Option 1: Shared Filesystem (Recommended)

```
Plex Server                    GPU Worker
    │                              │
    │ ────── SMB/NFS Share ─────── │
    │                              │
/srv/media ◄───────────────► Z:\media
```

Both Plex and the worker access the same files via network share.

**Pros:** Simple, worker reads files directly
**Cons:** Requires network storage setup

### Option 2: HTTP Streaming

Worker fetches input via Plex's streaming API:

```
Worker ──► GET http://plex:32400/library/parts/123/file.mkv?X-Plex-Token=xxx
```

**Pros:** No shared storage needed
**Cons:** Additional network overhead

### Option 3: Segment-Only Remote

Cartridge streams input to worker, worker returns segments:

```
Cartridge ──► POST /transcode (with file chunks)
             ◄── Response: HLS segments
```

**Pros:** Maximum flexibility
**Cons:** High bandwidth, complex implementation

## Hardware Acceleration

### Intel QSV

```bash
ffmpeg -hwaccel qsv -c:v h264_qsv \
  -i input.mkv \
  -c:v h264_qsv -preset fast -global_quality 23 \
  -c:a aac -b:a 128k \
  output.mp4
```

Requirements:
- Intel 6th gen (Skylake) or newer CPU
- Windows: Intel Media SDK / oneAPI VPL
- Linux: libva, intel-media-driver

### NVIDIA NVENC

```bash
ffmpeg -hwaccel cuda -c:v h264_nvenc \
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
┌─────────────────────────────────────┐
│ Try remote worker                   │
│                                     │
│ ┌─ Health check GET /health ──────┐ │
│ │                                 │ │
│ │  Success? ──► Dispatch job      │ │
│ │  Failure? ──► Fall back         │ │
│ └─────────────────────────────────┘ │
│                                     │
│ ┌─ If remote fails ───────────────┐ │
│ │                                 │ │
│ │  FALLBACK_TO_LOCAL=true?        │ │
│ │  Yes ──► Run local transcoder   │ │
│ │  No  ──► Exit with error        │ │
│ └─────────────────────────────────┘ │
└─────────────────────────────────────┘
```

## Scaling

### Multiple Workers

```
                    ┌─── Worker 1 (Intel QSV)
                    │
Cartridge ──────────┼─── Worker 2 (NVIDIA)
                    │
                    └─── Worker 3 (Intel QSV)
```

Future: Load balancer in front of workers, or cartridge round-robins.

### Containerization

```yaml
# docker-compose.yml
services:
  plex:
    image: plexinc/pms-docker
    volumes:
      - ./cartridge:/opt/plex-cartridge

  worker:
    build: ./worker
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
```

## Security Considerations

1. **API Key Authentication:** Worker can require X-API-Key header
2. **Network Isolation:** Worker should only be accessible from Plex server
3. **Input Validation:** Worker validates job requests
4. **Resource Limits:** Max concurrent jobs, timeouts

## Monitoring

### Logs

- `/var/log/plex-cartridge/master.log` - One line per transcode
- `/var/log/plex-cartridge/cartridge_events.log` - Events, errors, updates
- `/var/log/plex-cartridge/sessions/` - Full session details

### Analysis

```bash
# View transcode summary
sudo /opt/plex-cartridge/analyze.sh

# Check remote feasibility
sudo /opt/plex-cartridge/analyze.sh --remote-feasibility

# View specific session
sudo /opt/plex-cartridge/analyze.sh --detail 20250205_143022_12345
```

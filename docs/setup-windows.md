# Windows GPU Worker Setup Guide

This guide covers setting up the PlexBeam GPU worker on Windows with Intel QSV or NVIDIA NVENC.

> **Important:** On Windows, QSV uses **encode-only** mode (software decode + QSV encode). This is the default behavior and works great -- typically 80+ fps / 3.5x speed for 1080p content. Full QSV decode+encode is not supported on Windows.

## Prerequisites

- Windows 10/11
- Python 3.10 or newer
- FFmpeg with hardware acceleration support
- Intel 6th gen+ CPU (for QSV) OR NVIDIA GTX 900+/RTX (for NVENC)

## Step 1: Install FFmpeg with Hardware Acceleration

### Option A: Pre-built with QSV/NVENC

Download from: https://github.com/BtbN/FFmpeg-Builds/releases

Choose: `ffmpeg-master-latest-win64-gpl.zip`

```powershell
# Extract and add to PATH
Expand-Archive ffmpeg-master-latest-win64-gpl.zip -DestinationPath C:\ffmpeg
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\ffmpeg\bin", "User")
```

### Option B: Using Chocolatey

```powershell
choco install ffmpeg-full
```

### Verify FFmpeg

```powershell
ffmpeg -version
ffmpeg -encoders | Select-String "qsv|nvenc"
```

Expected output should include `h264_qsv` or `h264_nvenc`.

## Step 2: Install Intel/NVIDIA Drivers

### Intel QSV

1. Download Intel Graphics Driver: https://www.intel.com/content/www/us/en/download/19344/intel-graphics-windows-dch-drivers.html
2. Install and reboot
3. Verify QSV encoding works:

```powershell
ffmpeg -f lavfi -i testsrc=duration=5:size=1920x1080 -c:v h264_qsv -preset veryfast -f null -
```

You should see it complete without errors and report the fps.

### NVIDIA NVENC

1. Install latest NVIDIA drivers: https://www.nvidia.com/drivers
2. Verify:

```powershell
ffmpeg -f lavfi -i testsrc=duration=5:size=1920x1080 -c:v h264_nvenc -preset p4 -f null -
```

## Step 3: Install Python Dependencies

```powershell
# Navigate to worker directory
cd C:\path\to\plexbeam\worker

# Create virtual environment (recommended)
python -m venv venv
.\venv\Scripts\Activate.ps1

# Install dependencies
pip install -r requirements.txt
```

## Step 4: Configure the Worker

Create a `.env` file in the worker directory:

```ini
# .env
PLEX_WORKER_HOST=0.0.0.0
PLEX_WORKER_PORT=8765

# Hardware acceleration (qsv, nvenc, none)
PLEX_WORKER_HW_ACCEL=qsv

# Media path mapping (required when Plex runs in Docker)
# Maps Docker container paths to Windows host paths
# PLEX_WORKER_MEDIA_PATH_FROM=/media
# PLEX_WORKER_MEDIA_PATH_TO=C:/Users/you/media

# Optional: API key for authentication
# PLEX_WORKER_API_KEY=your-secret-key

# Job limits
PLEX_WORKER_MAX_CONCURRENT_JOBS=2
```

### Configuration Options

| Variable | Default | Description |
|----------|---------|-------------|
| `PLEX_WORKER_HOST` | `0.0.0.0` | Listen address |
| `PLEX_WORKER_PORT` | `8765` | Listen port |
| `PLEX_WORKER_HW_ACCEL` | `qsv` | Hardware accel (qsv/nvenc/none) |
| `PLEX_WORKER_FFMPEG_PATH` | `ffmpeg` | FFmpeg executable path |
| `PLEX_WORKER_FFPROBE_PATH` | `ffprobe` | FFprobe executable path |
| `PLEX_WORKER_MEDIA_PATH_FROM` | - | Container media path prefix to replace |
| `PLEX_WORKER_MEDIA_PATH_TO` | - | Host media path to replace with |
| `PLEX_WORKER_API_KEY` | - | API authentication key |
| `PLEX_WORKER_MAX_CONCURRENT_JOBS` | `2` | Max parallel jobs |
| `PLEX_WORKER_QSV_PRESET` | `fast` | QSV encoder preset |
| `PLEX_WORKER_QSV_QUALITY` | `23` | QSV quality (1-51, lower=better) |
| `PLEX_WORKER_NVENC_PRESET` | `p4` | NVENC preset (p1-p7, p1=fastest) |
| `PLEX_WORKER_TEMP_DIR` | `./transcode_temp` | Temp directory |
| `PLEX_WORKER_LOG_DIR` | `./logs` | Log directory |
| `PLEX_WORKER_JOB_TIMEOUT` | `3600` | Job timeout in seconds |

## Step 5: Run the Worker

### Manual Start

```powershell
cd C:\path\to\plexbeam\worker
.\venv\Scripts\Activate.ps1
python worker.py
```

### Verify It's Running

```powershell
# In another terminal
curl http://localhost:8765/health
```

Expected response:
```json
{
  "status": "healthy",
  "hw_accel": "qsv",
  "active_jobs": 0,
  "ffmpeg_available": true
}
```

## Step 6: Configure Firewall

Allow incoming connections on port 8765:

```powershell
# PowerShell (Admin)
New-NetFirewallRule -DisplayName "Plex GPU Worker" -Direction Inbound -Port 8765 -Protocol TCP -Action Allow
```

Or via GUI: Windows Defender Firewall -> Advanced Settings -> Inbound Rules -> New Rule

## Step 7: Connect to Plex

### Option A: Plex in Docker (Recommended)

Run Plex in Docker with the PlexBeam cartridge pre-installed, and point it at your bare-metal worker:

1. In the project root `.env`, set:
   ```ini
   PLEXBEAM_WORKER_URL=http://host.docker.internal:8765
   ```

2. Start Plex:
   ```bash
   docker compose up -d plex
   ```

3. Configure media path mapping in `worker/.env` so the worker can resolve Docker container paths to Windows paths:
   ```ini
   # Docker mounts media at /media, but on Windows it lives elsewhere
   PLEX_WORKER_MEDIA_PATH_FROM=/media
   PLEX_WORKER_MEDIA_PATH_TO=C:/Users/you/media
   ```

> **Note:** Intel GPU Docker workers do NOT work on Windows. WSL2 lacks the i915/KMS drivers needed for QSV. The bare-metal worker approach described here is the correct solution.

### Option B: Bare-Metal Plex Server (Linux)

Install the cartridge on your Linux Plex server:

```bash
sudo ./install.sh --worker http://192.168.1.100:8765
```

Replace `192.168.1.100` with your Windows worker's IP.

### Test It

Play something in Plex that triggers a transcode, then check:

```powershell
# Health check
curl http://localhost:8765/health

# Active jobs
curl http://localhost:8765/jobs
```

You should see an active job with `h264_qsv` or `h264_nvenc` as the encoder.

## Step 8: Run as Windows Service (Optional)

### Using NSSM (Recommended)

1. Download NSSM: https://nssm.cc/download
2. Install as service:

```powershell
nssm install PlexGPUWorker "C:\path\to\venv\Scripts\python.exe" "C:\path\to\worker\worker.py"
nssm set PlexGPUWorker AppDirectory "C:\path\to\worker"
nssm set PlexGPUWorker DisplayName "Plex Remote GPU Worker"
nssm set PlexGPUWorker Description "Handles remote GPU transcoding for Plex"
nssm set PlexGPUWorker Start SERVICE_AUTO_START
nssm start PlexGPUWorker
```

### Using Task Scheduler

1. Open Task Scheduler
2. Create Basic Task -> "Plex GPU Worker"
3. Trigger: When computer starts
4. Action: Start a program
5. Program: `C:\path\to\venv\Scripts\python.exe`
6. Arguments: `C:\path\to\worker\worker.py`
7. Start in: `C:\path\to\worker`
8. Check "Run whether user is logged on or not"

## Troubleshooting

### QSV Not Working

```powershell
# Check Intel GPU is recognized
Get-WmiObject Win32_VideoController | Select Name

# Test QSV encode (software decode + QSV encode)
ffmpeg -f lavfi -i testsrc=duration=5:size=1920x1080 -c:v h264_qsv -preset veryfast -f null -
```

Common fixes:
- Update Intel Graphics Driver
- Ensure "Intel Graphics" is enabled in Device Manager
- Check BIOS for iGPU settings (may be disabled when a discrete GPU is present)

### NVENC Not Working

```powershell
# Check NVIDIA GPU
nvidia-smi

# Test NVENC
ffmpeg -f lavfi -i testsrc=duration=5:size=1920x1080 -c:v h264_nvenc -preset p4 -f null -
```

Common fixes:
- Update NVIDIA drivers
- Consumer GPUs (GTX) have a 3-5 session limit; Quadro/RTX A-series are unlimited

### Connection Refused

```powershell
# Check service is listening
netstat -an | findstr 8765

# Check firewall
Get-NetFirewallRule -DisplayName "*Plex*"
```

### Media Path Errors

If the worker logs show "file not found" errors, your media path mapping is likely wrong:

```powershell
# Check what paths Plex is sending
curl http://localhost:8765/jobs
# Look at the input paths in the job details
```

The `PLEX_WORKER_MEDIA_PATH_FROM` should match the container mount point (e.g., `/media`) and `PLEX_WORKER_MEDIA_PATH_TO` should be the corresponding Windows path (e.g., `C:/Users/you/media`).

## Performance Tuning

### Intel QSV

```ini
# Quality vs speed tradeoff
PLEX_WORKER_QSV_PRESET=faster  # Options: veryslow, slower, slow, medium, fast, faster, veryfast

# Higher quality (more bitrate)
PLEX_WORKER_QSV_QUALITY=20  # Lower = better quality, higher bitrate
```

### NVIDIA NVENC

```ini
PLEX_WORKER_NVENC_PRESET=p4  # p1=fastest, p7=best quality
```

### Multiple Concurrent Jobs

Intel QSV and NVENC can handle 2-4 concurrent streams depending on resolution:

```ini
PLEX_WORKER_MAX_CONCURRENT_JOBS=3
```

Monitor GPU utilization:
- Intel: Task Manager -> Performance -> GPU
- NVIDIA: `nvidia-smi` or Task Manager

# Windows GPU Worker Setup Guide

This guide covers setting up the PlexBeam GPU worker on Windows with Intel QSV or NVIDIA NVENC.

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
3. Verify:

```powershell
ffmpeg -init_hw_device qsv=qsv -f lavfi -i testsrc=duration=1 -c:v h264_qsv -f null -
```

### NVIDIA NVENC

1. Install latest NVIDIA drivers: https://www.nvidia.com/drivers
2. Verify:

```powershell
ffmpeg -init_hw_device cuda=cuda -f lavfi -i testsrc=duration=1 -c:v h264_nvenc -f null -
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

# Hardware acceleration (qsv, nvenc, vaapi, none)
PLEX_WORKER_HW_ACCEL=qsv

# Paths
PLEX_WORKER_FFMPEG_PATH=C:\ffmpeg\bin\ffmpeg.exe
PLEX_WORKER_FFPROBE_PATH=C:\ffmpeg\bin\ffprobe.exe
PLEX_WORKER_TEMP_DIR=C:\PlexTranscode\temp
PLEX_WORKER_LOG_DIR=C:\PlexTranscode\logs

# Optional: Shared storage where Plex can read output
# PLEX_WORKER_SHARED_OUTPUT_DIR=\\\\PLEXSERVER\\transcode

# Optional: API key for authentication
# PLEX_WORKER_API_KEY=your-secret-key

# QSV-specific
PLEX_WORKER_QSV_PRESET=fast
PLEX_WORKER_QSV_QUALITY=23

# Job limits
PLEX_WORKER_MAX_CONCURRENT_JOBS=2
PLEX_WORKER_JOB_TIMEOUT=3600
```

### Configuration Options

| Variable | Default | Description |
|----------|---------|-------------|
| `PLEX_WORKER_HOST` | `0.0.0.0` | Listen address |
| `PLEX_WORKER_PORT` | `8765` | Listen port |
| `PLEX_WORKER_HW_ACCEL` | `qsv` | Hardware accel (qsv/nvenc/vaapi/none) |
| `PLEX_WORKER_FFMPEG_PATH` | `ffmpeg` | FFmpeg executable path |
| `PLEX_WORKER_TEMP_DIR` | `./transcode_temp` | Temp directory |
| `PLEX_WORKER_SHARED_OUTPUT_DIR` | - | Shared output for Plex |
| `PLEX_WORKER_API_KEY` | - | API authentication key |
| `PLEX_WORKER_MAX_CONCURRENT_JOBS` | `2` | Max parallel jobs |
| `PLEX_WORKER_QSV_PRESET` | `fast` | QSV encoder preset |
| `PLEX_WORKER_QSV_QUALITY` | `23` | QSV quality (1-51, lower=better) |

## Step 5: Run the Worker

### Manual Start

```powershell
cd C:\path\to\plexbeam\worker
.\venv\Scripts\Activate.ps1
python worker.py
```

### Using Uvicorn Directly

```powershell
uvicorn worker:app --host 0.0.0.0 --port 8765
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
  "version": "1.0.0",
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

Or via GUI: Windows Defender Firewall → Advanced Settings → Inbound Rules → New Rule

## Step 7: Run as Windows Service (Optional)

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
2. Create Basic Task → "Plex GPU Worker"
3. Trigger: When computer starts
4. Action: Start a program
5. Program: `C:\path\to\venv\Scripts\python.exe`
6. Arguments: `C:\path\to\worker\worker.py`
7. Start in: `C:\path\to\worker`
8. Check "Run whether user is logged on or not"

## Step 8: Test with Plex

### From Plex Server

```bash
# Test the worker
curl http://192.168.1.100:8765/health

# Send a test job
curl -X POST http://192.168.1.100:8765/transcode \
  -H "Content-Type: application/json" \
  -d '{
    "job_id": "test_001",
    "input": {"type": "file", "path": "C:\\Videos\\test.mkv"},
    "output": {"type": "hls", "path": "C:\\PlexTranscode\\test"},
    "arguments": {"video_codec": "h264", "hw_accel": "qsv"}
  }'
```

### Install Cartridge on Plex Server

```bash
sudo ./install.sh --worker http://192.168.1.100:8765
```

Play something in Plex that triggers a transcode and watch the worker logs.

## Shared Storage Setup

For best results, set up shared storage so both Plex and the worker can access the same files.

### Option 1: SMB Share from Plex Server

On Linux Plex server:
```bash
# Install Samba
sudo apt install samba

# Share transcode directory
echo "[transcode]
path = /var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Cache/Transcode
writable = yes
guest ok = yes" | sudo tee -a /etc/samba/smb.conf

sudo systemctl restart smbd
```

On Windows worker, map the share:
```powershell
net use Z: \\192.168.1.50\transcode
```

Set in `.env`:
```ini
PLEX_WORKER_SHARED_OUTPUT_DIR=Z:\Sessions
```

### Option 2: Network Media on NAS

If your media is on a NAS accessible to both:
- Plex reads from `/mnt/nas/media`
- Worker reads from `\\NAS\media`

No additional setup needed - just ensure paths match.

## Troubleshooting

### QSV Not Working

```powershell
# Check Intel GPU is recognized
Get-WmiObject Win32_VideoController | Select Name

# Test QSV directly
ffmpeg -init_hw_device qsv=qsv -f lavfi -i testsrc=duration=1 -c:v h264_qsv -f null - -v verbose
```

Common fixes:
- Update Intel Graphics Driver
- Ensure "Intel Graphics" is enabled in Device Manager
- Check BIOS for iGPU settings

### NVENC Not Working

```powershell
# Check NVIDIA GPU
nvidia-smi

# Test NVENC
ffmpeg -init_hw_device cuda=cuda -f lavfi -i testsrc=duration=1 -c:v h264_nvenc -f null - -v verbose
```

Common fixes:
- Update NVIDIA drivers
- Check GPU supports NVENC (consumer GPUs have session limits)

### Connection Refused

```powershell
# Check service is listening
netstat -an | findstr 8765

# Check firewall
Get-NetFirewallRule | Where-Object {$_.LocalPort -eq 8765}
```

### Worker Crashes

Check logs:
```powershell
type C:\PlexTranscode\logs\worker.log
```

Common issues:
- FFmpeg not in PATH
- Permission denied on temp directory
- Out of disk space

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
- Intel: Task Manager → Performance → GPU
- NVIDIA: `nvidia-smi` or Task Manager

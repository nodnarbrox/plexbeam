"""
Plex Remote GPU Worker - FastAPI Service

Receives transcode jobs from the Plex cartridge and executes them
using hardware-accelerated FFmpeg.
"""
import asyncio
import logging
import os
import sys
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, BackgroundTasks, WebSocket, WebSocketDisconnect, Header, Request
from fastapi.responses import JSONResponse, FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from config import settings, init_directories
from transcoder import TranscodeJob, TranscodeProgress, transcoder, parse_plex_args_to_job

# Configure logging
logging.basicConfig(
    level=getattr(logging, settings.log_level),
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(settings.log_dir / "worker.log")
    ]
)
logger = logging.getLogger("plex-worker")


# ============================================================================
# Request/Response Models
# ============================================================================

class TranscodeRequest(BaseModel):
    """Request to start a transcode job."""
    job_id: str = Field(description="Unique job identifier")
    input: dict = Field(description="Input specification")
    output: dict = Field(description="Output specification")
    arguments: dict = Field(default_factory=dict, description="Transcode arguments")
    priority: int = Field(default=5, ge=1, le=10)
    timeout: int = Field(default=3600)
    callback_url: Optional[str] = None
    metadata: dict = Field(default_factory=dict)
    source: str = Field(default="plex", description="Source server type (plex or jellyfin)")


class TranscodeResponse(BaseModel):
    """Response for transcode job creation."""
    job_id: str
    status: str
    message: str


class JobStatus(BaseModel):
    """Status of a transcode job."""
    job_id: str
    status: str  # queued, running, completed, failed, cancelled
    progress: float = 0.0
    fps: float = 0.0
    speed: float = 0.0
    current_segment: Optional[int] = None
    eta_seconds: Optional[int] = None
    error: Optional[str] = None
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None


class HealthResponse(BaseModel):
    """Health check response."""
    status: str
    version: str
    hw_accel: str
    active_jobs: int
    ffmpeg_available: bool


# ============================================================================
# Job Queue and State
# ============================================================================

class JobQueue:
    """Manages transcode job queue and execution."""

    def __init__(self):
        self.jobs: dict[str, TranscodeJob] = {}
        self.queue: asyncio.Queue = asyncio.Queue()
        self.active_jobs: set[str] = set()
        self.workers: list[asyncio.Task] = []
        self.websocket_connections: dict[str, list[WebSocket]] = {}

    async def start_workers(self):
        """Start background worker tasks."""
        for i in range(settings.max_concurrent_jobs):
            task = asyncio.create_task(self._worker(i))
            self.workers.append(task)
        logger.info(f"Started {settings.max_concurrent_jobs} worker(s)")

    async def stop_workers(self):
        """Stop all worker tasks."""
        for task in self.workers:
            task.cancel()
        await asyncio.gather(*self.workers, return_exceptions=True)
        self.workers.clear()

    async def _worker(self, worker_id: int):
        """Background worker that processes jobs from queue."""
        logger.info(f"Worker {worker_id} started")
        while True:
            try:
                job = await self.queue.get()
                self.active_jobs.add(job.job_id)

                logger.info(f"Worker {worker_id} processing job {job.job_id}")

                try:
                    success = await transcoder.transcode(
                        job,
                        progress_callback=lambda p: self._broadcast_progress(p)
                    )

                    if success:
                        logger.info(f"Job {job.job_id} completed successfully")
                    else:
                        logger.error(f"Job {job.job_id} failed: {job.progress.error}")

                except asyncio.CancelledError:
                    logger.info(f"Worker {worker_id} cancelled during job {job.job_id}")
                    raise
                except Exception as e:
                    logger.exception(f"Error processing job {job.job_id}: {e}")
                    job.progress.status = "failed"
                    job.progress.error = str(e)
                finally:
                    self.active_jobs.discard(job.job_id)
                    self.queue.task_done()
                    self._broadcast_progress(job.progress)

            except asyncio.CancelledError:
                break

    def _broadcast_progress(self, progress: TranscodeProgress):
        """Broadcast progress to connected WebSocket clients."""
        asyncio.create_task(self._async_broadcast(progress))

    async def _async_broadcast(self, progress: TranscodeProgress):
        """Async broadcast to WebSocket clients."""
        connections = self.websocket_connections.get(progress.job_id, [])
        for ws in connections[:]:  # Copy list to avoid modification during iteration
            try:
                await ws.send_json({
                    "job_id": progress.job_id,
                    "status": progress.status,
                    "progress": progress.progress,
                    "fps": progress.fps,
                    "speed": progress.speed,
                    "error": progress.error
                })
            except Exception:
                connections.remove(ws)

    async def submit_job(self, job: TranscodeJob) -> None:
        """Submit a job to the queue."""
        self.jobs[job.job_id] = job
        job.progress.status = "queued"
        await self.queue.put(job)
        logger.info(f"Job {job.job_id} queued (queue size: {self.queue.qsize()})")

    def get_job(self, job_id: str) -> Optional[TranscodeJob]:
        """Get a job by ID."""
        return self.jobs.get(job_id)

    async def cancel_job(self, job_id: str) -> bool:
        """Cancel a job."""
        job = self.jobs.get(job_id)
        if not job:
            return False

        if job.progress.status == "running":
            await transcoder.cancel(job)
        elif job.progress.status == "queued":
            job.progress.status = "cancelled"

        return True

    def add_websocket(self, job_id: str, ws: WebSocket):
        """Add a WebSocket connection for job progress."""
        if job_id not in self.websocket_connections:
            self.websocket_connections[job_id] = []
        self.websocket_connections[job_id].append(ws)

    def remove_websocket(self, job_id: str, ws: WebSocket):
        """Remove a WebSocket connection."""
        if job_id in self.websocket_connections:
            try:
                self.websocket_connections[job_id].remove(ws)
            except ValueError:
                pass


# Global job queue
job_queue = JobQueue()


# ============================================================================
# FastAPI App
# ============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    # Startup
    init_directories()
    await job_queue.start_workers()
    logger.info(f"Plex Remote GPU Worker started on {settings.host}:{settings.port}")
    logger.info(f"Hardware acceleration: {settings.hw_accel}")

    yield

    # Shutdown
    await job_queue.stop_workers()
    logger.info("Worker shutdown complete")


app = FastAPI(
    title="Plex Remote GPU Worker",
    description="Receives transcode jobs from Plex and executes them with hardware acceleration",
    version="1.0.0",
    lifespan=lifespan
)


# ============================================================================
# Authentication Middleware
# ============================================================================

def verify_api_key(x_api_key: Optional[str] = Header(None)):
    """Verify API key if configured."""
    if settings.api_key and x_api_key != settings.api_key:
        raise HTTPException(status_code=401, detail="Invalid API key")


# ============================================================================
# Endpoints
# ============================================================================

@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint."""
    # Check FFmpeg availability
    ffmpeg_ok = os.path.exists(settings.ffmpeg_path) or bool(
        os.popen(f"which {settings.ffmpeg_path} 2>/dev/null || where {settings.ffmpeg_path} 2>nul").read()
    )

    return HealthResponse(
        status="healthy",
        version="1.0.0",
        hw_accel=settings.hw_accel,
        active_jobs=len(job_queue.active_jobs),
        ffmpeg_available=ffmpeg_ok
    )


@app.post("/transcode", response_model=TranscodeResponse)
async def create_transcode_job(
    request: TranscodeRequest,
    background_tasks: BackgroundTasks,
    x_api_key: Optional[str] = Header(None)
):
    """Create a new transcode job."""
    verify_api_key(x_api_key)

    # Determine input path
    input_spec = request.input
    if input_spec.get("type") == "file":
        input_path = input_spec.get("path", "")
    elif input_spec.get("type") == "http":
        input_path = input_spec.get("url", "")
    else:
        input_path = input_spec.get("path") or input_spec.get("url", "")

    # Strip Jellyfin's file: protocol prefix (e.g., file:/media/foo -> /media/foo)
    if input_path.startswith('file:"') and input_path.endswith('"'):
        input_path = input_path[6:-1]
    elif input_path.startswith("file:"):
        input_path = input_path[5:]

    # Apply media path mapping for build_ffmpeg_command path (raw passthrough does its own)
    if settings.media_path_from and settings.media_path_to:
        if input_path.startswith(settings.media_path_from):
            input_path = settings.media_path_to + input_path[len(settings.media_path_from):]

    if not input_path:
        raise HTTPException(status_code=400, detail="No input path or URL provided")

    # Determine output path
    output_spec = request.output
    if settings.shared_output_dir:
        output_dir = settings.shared_output_dir / request.job_id
    else:
        output_dir = settings.temp_dir / request.job_id

    output_dir.mkdir(parents=True, exist_ok=True)

    # Check if we should use raw passthrough mode (no output path specified by cartridge)
    use_raw_passthrough = output_spec.get("type") == "unknown" or not output_spec.get("path")

    if output_spec.get("type") == "hls":
        output_path = output_dir / "output.m3u8"
        output_type = "hls"
    elif output_spec.get("type") == "dash":
        output_path = output_dir / "output.mpd"
        output_type = "dash"
    elif use_raw_passthrough:
        output_path = ""  # Empty for raw passthrough
        output_type = "raw"
    else:
        output_path = output_dir / "output.mp4"
        output_type = "file"

    # Build job from request
    args = request.arguments
    source = request.source
    logger.info(f"[{request.job_id}] Source: {source}, input_path: {input_path}")
    job = TranscodeJob(
        job_id=request.job_id,
        input_path=input_path,
        output_path=str(output_path),
        video_codec=args.get("video_codec", "h264"),
        audio_codec=args.get("audio_codec", "aac"),
        video_bitrate=args.get("video_bitrate"),
        audio_bitrate=args.get("audio_bitrate", "128k"),
        resolution=args.get("resolution"),
        preset=args.get("preset", "fast"),
        quality=args.get("quality", 23),
        hw_accel=args.get("hw_accel", settings.hw_accel),
        seek=args.get("seek"),
        duration=args.get("duration"),
        filters=args.get("filters", []),
        subtitle_path=args.get("subtitle", {}).get("path") if isinstance(args.get("subtitle"), dict) else None,
        subtitle_burn=args.get("subtitle", {}).get("mode") == "burn" if isinstance(args.get("subtitle"), dict) else False,
        tone_mapping=args.get("tone_mapping", False),
        output_type=output_type,
        segment_duration=output_spec.get("segment_duration", 4),
        raw_args=args.get("raw_args", []),
        source=source
    )

    # Submit to queue
    await job_queue.submit_job(job)

    return TranscodeResponse(
        job_id=job.job_id,
        status="queued",
        message=f"Job queued. Output at: {output_dir}"
    )


@app.post("/transcode/raw", response_model=TranscodeResponse)
async def create_raw_transcode_job(
    job_id: str,
    args: list[str],
    x_api_key: Optional[str] = Header(None)
):
    """
    Create a transcode job from raw Plex transcoder arguments.

    This endpoint accepts the raw arguments that Plex passes to its transcoder,
    parses them, and executes with hardware acceleration.
    """
    verify_api_key(x_api_key)

    if settings.shared_output_dir:
        output_dir = settings.shared_output_dir / job_id
    else:
        output_dir = settings.temp_dir / job_id

    output_dir.mkdir(parents=True, exist_ok=True)

    job = parse_plex_args_to_job(job_id, args, output_dir)
    await job_queue.submit_job(job)

    return TranscodeResponse(
        job_id=job.job_id,
        status="queued",
        message=f"Job queued from raw args. Output at: {output_dir}"
    )


@app.get("/status/{job_id}", response_model=JobStatus)
async def get_job_status(job_id: str, x_api_key: Optional[str] = Header(None)):
    """Get the status of a transcode job."""
    verify_api_key(x_api_key)

    job = job_queue.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    return JobStatus(
        job_id=job.job_id,
        status=job.progress.status,
        progress=job.progress.progress,
        fps=job.progress.fps,
        speed=job.progress.speed,
        current_segment=job.progress.current_segment,
        error=job.progress.error,
        started_at=job.started_at,
        completed_at=job.completed_at
    )


@app.delete("/job/{job_id}")
async def cancel_job(job_id: str, x_api_key: Optional[str] = Header(None)):
    """Cancel a transcode job."""
    verify_api_key(x_api_key)

    success = await job_queue.cancel_job(job_id)
    if not success:
        raise HTTPException(status_code=404, detail="Job not found")

    return {"status": "cancelled", "job_id": job_id}


@app.get("/jobs")
async def list_jobs(x_api_key: Optional[str] = Header(None)):
    """List all jobs."""
    verify_api_key(x_api_key)

    return {
        "jobs": [
            {
                "job_id": job.job_id,
                "status": job.progress.status,
                "progress": job.progress.progress,
                "started_at": job.started_at.isoformat() if job.started_at else None
            }
            for job in job_queue.jobs.values()
        ],
        "queue_size": job_queue.queue.qsize(),
        "active_jobs": len(job_queue.active_jobs)
    }


@app.websocket("/ws/progress/{job_id}")
async def websocket_progress(websocket: WebSocket, job_id: str):
    """WebSocket endpoint for real-time job progress."""
    await websocket.accept()
    job_queue.add_websocket(job_id, websocket)

    try:
        # Send initial status
        job = job_queue.get_job(job_id)
        if job:
            await websocket.send_json({
                "job_id": job_id,
                "status": job.progress.status,
                "progress": job.progress.progress
            })

        # Keep connection alive and receive pings
        while True:
            try:
                data = await asyncio.wait_for(websocket.receive_text(), timeout=30)
                if data == "ping":
                    await websocket.send_text("pong")
            except asyncio.TimeoutError:
                # Send keepalive
                await websocket.send_text("keepalive")

    except WebSocketDisconnect:
        pass
    finally:
        job_queue.remove_websocket(job_id, websocket)


# ============================================================================
# Streaming Transcode Helpers
# ============================================================================

def _filter_plex_stream_args(raw_args: list[str]) -> list[str]:
    """
    Filter Plex-specific args for the streaming transcode endpoint.

    Handles all Plex-specific option stripping, HEVC->H.264 transcoding,
    HW encoder replacement, filter_complex skipping, map fixing,
    x264opts/preset:0 stripping, aac_lc->aac, ochl rewrite, VAAPI injection,
    and media path mapping.
    """
    import re
    import subprocess as _sp

    plex_opts_with_value = {
        "-loglevel_plex", "-progressurl", "-loglevel",
        "-delete_removed", "-skip_to_segment", "-manifest_name", "-time_delta",
        "-seg_duration", "-dash_segment_type", "-init_seg_name",
        "-media_seg_name", "-window_size",
        # Linux VAAPI options - not available on Windows
        "-hwaccel", "-hwaccel:0", "-hwaccel_device", "-hwaccel_device:0",
        "-init_hw_device", "-filter_hw_device"
    }
    plex_opts_no_value = {"-nostats", "-noaccurate_seek"}

    # Detect if HEVC copy is requested - we need to transcode to H.264 for browser playback
    is_hevc_input = False
    has_video_copy = False
    needs_video_transcode = False
    for i, arg in enumerate(raw_args):
        if arg == "-codec:0" and i + 1 < len(raw_args) and raw_args[i + 1] == "hevc":
            is_hevc_input = True
        if arg == "-codec:0" and i + 1 < len(raw_args) and raw_args[i + 1] == "copy":
            has_video_copy = True
        # Detect if Plex is requesting actual transcoding (libx264, etc)
        if arg == "-codec:0" and i + 1 < len(raw_args) and raw_args[i + 1] in ("libx264", "h264"):
            needs_video_transcode = True
        if arg.startswith("-init_hw_device") and "vaapi" in arg:
            needs_video_transcode = True  # Linux GPU transcode requested

    # Track if we skip a video filter_complex so we can fix map references
    skipped_video_filter = False
    video_filter_output_label = None
    for i, arg in enumerate(raw_args):
        if arg == "-filter_complex" and i + 1 < len(raw_args):
            fc = raw_args[i + 1]
            if "scale=" in fc and "format=" in fc:
                match = re.search(r'(\[[0-9]+\])$', fc)
                if match:
                    video_filter_output_label = match.group(1)
                    logger.info(f"Found video filter output label: {video_filter_output_label}")

    filtered_args = []
    skip_next = False
    skip_f_format = False
    skip_filter_complex = False
    for i, arg in enumerate(raw_args):
        if skip_next:
            skip_next = False
            continue
        if skip_f_format:
            skip_f_format = False
            continue
        if skip_filter_complex:
            skip_filter_complex = False
            continue
        if arg in plex_opts_with_value:
            skip_next = True
            continue
        if arg in plex_opts_no_value:
            continue
        # Skip Plex's Linux VAAPI args (we add our own based on hw_accel setting)
        if "vaapi" in str(arg).lower() and settings.hw_accel != "vaapi":
            continue
        # Skip -f dash/hls (we'll add our own -f mpegts)
        if arg == "-f" and i + 1 < len(raw_args) and raw_args[i + 1] in ("dash", "hls"):
            skip_f_format = True
            continue
        # Skip standalone output format at end
        if arg in ("dash", "hls") or arg.endswith(".mpd") or arg.endswith(".m3u8"):
            continue
        # If HEVC input with video copy, transcode to H.264 instead for browser compatibility
        if is_hevc_input and has_video_copy and arg == "-codec:0" and i + 1 < len(raw_args) and raw_args[i + 1] == "copy":
            hw_encoder = settings.get_video_encoder()
            hw_accel = settings.hw_accel
            # Downscale to 1080p max (community preference: don't transcode at 4K)
            scale_filter = "format=nv12,hwupload,scale_vaapi=w=1920:h=-2" if hw_accel == "vaapi" else "scale=1920:-2"
            encoder_opts = ["-c:v", hw_encoder]
            if hw_accel == "vaapi":
                encoder_opts.extend(["-qp", "26"])
            elif hw_accel == "none":
                encoder_opts.extend(["-preset", "veryfast", "-crf", "26"])
            else:
                encoder_opts.extend(["-preset", "veryfast", "-global_quality", "26"])
            filtered_args.extend([
                "-vf", scale_filter,
                *encoder_opts,
                "-maxrate", "10M", "-bufsize", "5M",
                "-g", "48", "-bf", "0"
            ])
            skip_next = True
            continue
        # If Linux GPU transcode requested, replace with HW encoder
        if needs_video_transcode and arg == "-codec:0" and i + 1 < len(raw_args) and raw_args[i + 1] == "libx264":
            hw_encoder = settings.get_video_encoder()
            hw_accel = settings.hw_accel
            scale_filter = "format=nv12,hwupload,scale_vaapi=w=1920:h=-2" if hw_accel == "vaapi" else "scale=1920:-2"
            encoder_opts = ["-c:v", hw_encoder]
            if hw_accel == "vaapi":
                encoder_opts.extend(["-qp", "26"])
            elif hw_accel == "none":
                encoder_opts.extend(["-preset", "veryfast", "-crf", "26"])
            else:
                encoder_opts.extend(["-preset", "veryfast", "-global_quality", "26"])
            filtered_args.extend([
                "-vf", scale_filter,
                *encoder_opts,
                "-maxrate", "10M", "-bufsize", "5M",
                "-g", "48", "-bf", "0"
            ])
            skip_next = True
            continue
        # Skip high bitrate settings from Plex (we use our own lower limits)
        if arg in ("-maxrate:0", "-bufsize:0", "-crf:0"):
            skip_next = True
            continue
        # Skip video filter_complex that references hw devices (use simpler version)
        if arg == "-filter_complex" and i + 1 < len(raw_args) and ("scale=" in raw_args[i + 1] or "format=" in raw_args[i + 1]):
            # Skip complex video scaling filters, QSV will handle it
            skip_filter_complex = True
            skipped_video_filter = True
            continue
        # Fix map reference if we skipped video filter - replace [1] with 0:0
        if skipped_video_filter and arg == "-map" and i + 1 < len(raw_args) and video_filter_output_label:
            if raw_args[i + 1] == video_filter_output_label:
                logger.info(f"Replacing -map {raw_args[i + 1]} with -map 0:0")
                filtered_args.extend(["-map", "0:0"])
                skip_next = True
                continue
        # Skip x264opts when using HW encoding (not compatible with QSV/NVENC/VAAPI)
        if settings.hw_accel != "none" and arg.startswith("-x264opts"):
            skip_next = True
            continue
        # Skip -preset:0 when using HW encoding (x264/x265 option, not for VAAPI/QSV/NVENC)
        if settings.hw_accel != "none" and arg == "-preset:0":
            skip_next = True
            continue
        # Replace Plex-specific codec names with standard ffmpeg equivalents
        if arg == "aac_lc":
            filtered_args.append("aac")
            continue
        # Rewrite Plex 'ochl' for old ffmpeg (<5.0) that only knows 'ocl'.
        if "ochl=" in arg:
            try:
                ver = _sp.check_output([settings.ffmpeg_path, "-version"], stderr=_sp.DEVNULL).decode()
                major = int(ver.split("version ")[1].split(".")[0])
                if major < 5:
                    arg = arg.replace("ochl=", "ocl=")
            except Exception:
                pass
        # Apply media path mapping for bare-metal workers
        if settings.media_path_from and settings.media_path_to:
            if arg.startswith(settings.media_path_from):
                arg = settings.media_path_to + arg[len(settings.media_path_from):]
        filtered_args.append(arg)

    # Inject VAAPI hardware acceleration args before -i
    # NOTE: Do NOT use -hwaccel_output_format vaapi — VGEM/WSL2 KMS limitation
    needs_hw_encode = is_hevc_input or needs_video_transcode
    if settings.hw_accel == "vaapi" and needs_hw_encode:
        device = settings.qsv_device or "/dev/dri/renderD128"
        vaapi_init = ["-hwaccel", "vaapi", "-vaapi_device", device]
        for idx, a in enumerate(filtered_args):
            if a == "-i":
                filtered_args[idx:idx] = vaapi_init
                break

    return filtered_args


def _filter_standard_stream_args(raw_args: list[str], output_format: str) -> list[str]:
    """
    Minimal filtering for standard ffmpeg args in streaming mode (e.g., Jellyfin).

    Jellyfin sends standard ffmpeg args. Only applies media path mapping and
    strips output format/path args (since we pipe to stdout).
    """
    filtered_args = []
    skip_next = False
    for i, arg in enumerate(raw_args):
        if skip_next:
            skip_next = False
            continue
        # Skip -f dash/hls (we'll add our own -f mpegts/etc)
        if arg == "-f" and i + 1 < len(raw_args) and raw_args[i + 1] in ("dash", "hls"):
            skip_next = True
            continue
        # Skip standalone output format at end
        if arg in ("dash", "hls") or arg.endswith(".mpd") or arg.endswith(".m3u8"):
            continue
        # Strip Jellyfin's file: protocol prefix (e.g., file:"/media/foo" -> /media/foo)
        if arg.startswith('file:"') and arg.endswith('"'):
            arg = arg[6:-1]  # strip file:" and trailing "
        elif arg.startswith("file:"):
            arg = arg[5:]
        # Apply media path mapping for bare-metal workers
        if settings.media_path_from and settings.media_path_to:
            if arg.startswith(settings.media_path_from):
                arg = settings.media_path_to + arg[len(settings.media_path_from):]
        filtered_args.append(arg)
    return filtered_args


# ============================================================================
# Streaming Transcode Endpoint
# ============================================================================

@app.post("/transcode/stream")
async def stream_transcode(request: Request):
    """
    Stream transcode output directly back to the client.
    The worker does GPU encoding and streams the result.
    Client receives raw video/audio stream to write locally.
    """
    body = await request.json()
    input_path = body.get("input_path", "")
    output_format = body.get("format", "mpegts")  # mpegts for streaming
    raw_args = body.get("raw_args", [])
    source = body.get("source", "plex")

    # Strip Jellyfin's file: protocol prefix
    if input_path.startswith('file:"') and input_path.endswith('"'):
        input_path = input_path[6:-1]
    elif input_path.startswith("file:"):
        input_path = input_path[5:]

    if not input_path:
        raise HTTPException(status_code=400, detail="No input_path provided")

    # Build FFmpeg command for streaming output with low-latency settings
    cmd = [settings.ffmpeg_path, "-y", "-nostdin",
           "-fflags", "+nobuffer+flush_packets",  # Reduce input buffering latency
           "-flags", "low_delay",
           "-probesize", "32768",  # Smaller probe for faster start
           "-analyzeduration", "500000"]  # 0.5 second analyze

    if source == "plex":
        filtered_args = _filter_plex_stream_args(raw_args)
    else:
        filtered_args = _filter_standard_stream_args(raw_args, output_format)

    cmd.extend(filtered_args)

    # Output to stdout in streamable format
    cmd.extend(["-f", output_format, "pipe:1"])

    logger.info(f"Streaming transcode: {' '.join(cmd)}")

    # Track the ffmpeg process so we can kill it on disconnect
    ffmpeg_proc = None

    async def generate():
        nonlocal ffmpeg_proc
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        ffmpeg_proc = process
        got_first_data = False

        try:
            while True:
                # Long timeout initially (ffmpeg needs to seek/probe), shorter once streaming
                timeout = 120 if not got_first_data else 30
                try:
                    chunk = await asyncio.wait_for(process.stdout.read(65536), timeout=timeout)
                except asyncio.TimeoutError:
                    logger.info(f"Stream timeout - no data for {timeout}s, killing ffmpeg")
                    break
                if not chunk:
                    break
                got_first_data = True
                yield chunk
        except (asyncio.CancelledError, GeneratorExit):
            logger.info("Stream client disconnected")
        finally:
            if process.returncode is None:
                logger.info(f"Killing ffmpeg process {process.pid}")
                process.kill()
                try:
                    await asyncio.wait_for(process.wait(), timeout=5)
                except asyncio.TimeoutError:
                    logger.warning(f"ffmpeg {process.pid} did not exit after kill")
            ffmpeg_proc = None

    async def on_disconnect_cleanup(response):
        """Ensure ffmpeg is killed if client disconnects."""
        if ffmpeg_proc and ffmpeg_proc.returncode is None:
            logger.info(f"Cleanup: killing orphaned ffmpeg {ffmpeg_proc.pid}")
            ffmpeg_proc.kill()

    response = StreamingResponse(
        generate(),
        media_type="video/mp2t" if output_format == "mpegts" else "application/octet-stream"
    )
    response.background = BackgroundTasks()
    response.background.add_task(on_disconnect_cleanup, response)
    return response


@app.get("/segments/{job_id}/{filename}")
async def get_segment(job_id: str, filename: str):
    """Serve segment files from completed transcode jobs."""
    segment_path = settings.temp_dir / job_id / filename
    if not segment_path.exists():
        # Also check in worker root (where relative paths end up)
        segment_path = Path(filename)
        if not segment_path.exists():
            raise HTTPException(status_code=404, detail="Segment not found")

    return FileResponse(segment_path)


# ============================================================================
# Main Entry Point
# ============================================================================

def main():
    """Run the worker service."""
    import uvicorn

    uvicorn.run(
        "worker:app",
        host=settings.host,
        port=settings.port,
        workers=settings.workers,
        log_level=settings.log_level.lower(),
        reload=False
    )


if __name__ == "__main__":
    main()

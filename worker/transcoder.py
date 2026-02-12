"""
Plex Remote GPU Worker - FFmpeg Transcoder with Hardware Acceleration
"""
import asyncio
import json
import logging
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import AsyncIterator, Optional, Callable

from config import settings

logger = logging.getLogger(__name__)


@dataclass
class TranscodeProgress:
    """Progress information for a transcode job."""
    job_id: str
    frame: int = 0
    fps: float = 0.0
    bitrate: str = ""
    total_size: int = 0
    out_time_ms: int = 0
    speed: float = 0.0
    progress: float = 0.0  # 0-100
    current_segment: Optional[int] = None
    status: str = "running"
    error: Optional[str] = None


@dataclass
class TranscodeJob:
    """Represents a transcode job."""
    job_id: str
    input_path: str
    output_path: str
    video_codec: str = "h264"
    audio_codec: str = "aac"
    video_bitrate: Optional[str] = None
    audio_bitrate: str = "128k"
    resolution: Optional[str] = None
    preset: str = "fast"
    quality: int = 23
    hw_accel: str = "qsv"
    seek: Optional[float] = None
    duration: Optional[float] = None
    filters: list[str] = field(default_factory=list)
    subtitle_path: Optional[str] = None
    subtitle_burn: bool = False
    tone_mapping: bool = False
    output_type: str = "hls"  # hls, dash, file
    segment_duration: int = 4
    raw_args: list[str] = field(default_factory=list)
    source: str = "plex"  # "plex" or "jellyfin"

    # Runtime state
    process: Optional[asyncio.subprocess.Process] = None
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    progress: TranscodeProgress = field(default_factory=lambda: TranscodeProgress(""))

    def __post_init__(self):
        self.progress = TranscodeProgress(self.job_id)


class FFmpegTranscoder:
    """Executes FFmpeg transcodes with hardware acceleration."""

    def __init__(self):
        self.ffmpeg_path = settings.ffmpeg_path
        self.ffprobe_path = settings.ffprobe_path

    async def probe_input(self, input_path: str) -> dict:
        """Get media information using ffprobe."""
        cmd = [
            self.ffprobe_path,
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            input_path
        ]

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await proc.communicate()

            if proc.returncode == 0:
                return json.loads(stdout.decode())
            else:
                logger.error(f"ffprobe failed: {stderr.decode()}")
                return {}
        except Exception as e:
            logger.error(f"ffprobe error: {e}")
            return {}

    def build_ffmpeg_command(self, job: TranscodeJob) -> list[str]:
        """Build the FFmpeg command for a transcode job."""
        cmd = [self.ffmpeg_path, "-y"]  # -y to overwrite

        # Hardware acceleration input
        hw_accel = job.hw_accel or settings.hw_accel
        if hw_accel == "qsv":
            cmd.extend(["-hwaccel", "qsv"])
            if settings.qsv_device:
                cmd.extend(["-qsv_device", settings.qsv_device])
            cmd.extend(["-hwaccel_output_format", "qsv"])
        elif hw_accel == "nvenc":
            cmd.extend(["-hwaccel", "cuda", "-hwaccel_output_format", "cuda"])
        elif hw_accel == "vaapi":
            device = settings.qsv_device or "/dev/dri/renderD128"
            cmd.extend(["-hwaccel", "vaapi", "-vaapi_device", device])
            # NOTE: Do NOT add -hwaccel_output_format vaapi here (VGEM/WSL2 KMS limitation)

        # Seek position
        if job.seek is not None:
            cmd.extend(["-ss", str(job.seek)])

        # Input
        cmd.extend(["-i", job.input_path])

        # Duration
        if job.duration is not None:
            cmd.extend(["-t", str(job.duration)])

        # Video encoding
        video_encoder = self._get_video_encoder(job.video_codec, hw_accel)
        cmd.extend(["-c:v", video_encoder])

        # Encoder-specific options
        if hw_accel == "qsv":
            cmd.extend([
                "-preset", job.preset,
                "-global_quality", str(job.quality)
            ])
            if job.video_bitrate:
                cmd.extend(["-b:v", job.video_bitrate])
        elif hw_accel == "nvenc":
            cmd.extend([
                "-preset", settings.nvenc_preset,
                "-cq", str(job.quality)
            ])
            if job.video_bitrate:
                cmd.extend(["-b:v", job.video_bitrate])
        elif hw_accel == "vaapi":
            if job.video_bitrate:
                cmd.extend(["-b:v", job.video_bitrate])
            else:
                cmd.extend(["-qp", str(job.quality)])
        else:
            # Software encoding
            cmd.extend([
                "-preset", job.preset,
                "-crf", str(job.quality)
            ])
            if job.video_bitrate:
                cmd.extend(["-b:v", job.video_bitrate, "-maxrate", job.video_bitrate])

        # Resolution scaling
        if job.resolution and "x" in job.resolution and job.resolution.replace("x", "").isdigit():
            width, height = job.resolution.split("x")
            if hw_accel == "qsv":
                cmd.extend(["-vf", f"scale_qsv=w={width}:h={height}"])
            elif hw_accel == "nvenc":
                cmd.extend(["-vf", f"scale_cuda={width}:{height}"])
            elif hw_accel == "vaapi":
                cmd.extend(["-vf", f"format=nv12,hwupload,scale_vaapi=w={width}:h={height}"])
            else:
                cmd.extend(["-vf", f"scale={width}:{height}"])

        # Filters (subtitle burn-in, etc.)
        if job.filters:
            # Combine with existing filters if any
            filter_str = ",".join(job.filters)
            if "-vf" in cmd:
                idx = cmd.index("-vf") + 1
                cmd[idx] = f"{cmd[idx]},{filter_str}"
            else:
                cmd.extend(["-vf", filter_str])

        # Subtitle burn-in
        if job.subtitle_burn and job.subtitle_path:
            sub_filter = f"subtitles={job.subtitle_path}"
            if "-vf" in cmd:
                idx = cmd.index("-vf") + 1
                cmd[idx] = f"{cmd[idx]},{sub_filter}"
            else:
                cmd.extend(["-vf", sub_filter])

        # Audio encoding (replace libfdk_aac with built-in aac if needed)
        audio_codec = job.audio_codec
        if audio_codec == "libfdk_aac":
            audio_codec = "aac"
        cmd.extend(["-c:a", audio_codec])
        if job.audio_bitrate:
            cmd.extend(["-b:a", job.audio_bitrate])

        # Output format
        if job.output_type == "hls":
            cmd.extend([
                "-f", "hls",
                "-hls_time", str(job.segment_duration),
                "-hls_list_size", "0",
                "-hls_flags", "independent_segments",
                "-hls_segment_filename", str(Path(job.output_path).parent / "segment_%04d.ts")
            ])
        elif job.output_type == "dash":
            cmd.extend([
                "-f", "dash",
                "-seg_duration", str(job.segment_duration),
                "-use_template", "1",
                "-use_timeline", "1"
            ])

        # Progress reporting
        cmd.extend(["-progress", "pipe:1", "-stats_period", "0.5"])

        # Output path
        cmd.append(job.output_path)

        return cmd

    def _get_video_encoder(self, codec: str, hw_accel: str) -> str:
        """Get the appropriate encoder based on codec and hardware acceleration."""
        if codec.lower() in ("copy", "passthrough"):
            return "copy"

        if codec.lower() in ("h264", "avc", "libx264"):
            encoders = {
                "qsv": "h264_qsv",
                "nvenc": "h264_nvenc",
                "vaapi": "h264_vaapi",
                "none": "libx264"
            }
        elif codec.lower() in ("hevc", "h265", "libx265"):
            encoders = {
                "qsv": "hevc_qsv",
                "nvenc": "hevc_nvenc",
                "vaapi": "hevc_vaapi",
                "none": "libx265"
            }
        else:
            return codec  # Use as-is

        return encoders.get(hw_accel, encoders["none"])

    def _filter_plex_args(self, job_id: str, raw_args: list[str], hw_accel: str, hw_encoder: str) -> list[str]:
        """
        Filter Plex-specific FFmpeg options from raw args.

        Plex's custom ffmpeg has options standard ffmpeg doesn't understand.
        This handles: plex_opts stripping, aac_lc->aac, ochl rewrite,
        libx264->HW encoder replacement, filter_complex skipping, map fixing,
        x264opts stripping, preset:0 stripping, VAAPI injection, media path mapping.
        """
        path_mappings = settings.get_path_mappings()

        # Plex-specific options to strip
        plex_opts_with_value = {
            "-loglevel_plex", "-progressurl", "-loglevel",
            "-delete_removed", "-skip_to_segment", "-manifest_name", "-time_delta",
            # Linux VAAPI options
            "-hwaccel", "-hwaccel:0", "-hwaccel_device", "-hwaccel_device:0",
            "-init_hw_device", "-filter_hw_device"
        }
        plex_opts_no_value = {"-nostats", "-noaccurate_seek"}

        # Detect if libx264 encoding is requested (replace with HW encoder if available)
        needs_hw_replace = hw_accel != "none" and any(
            raw_args[i] in ("-codec:0", "-c:v") and
            i + 1 < len(raw_args) and
            raw_args[i + 1] == "libx264"
            for i in range(len(raw_args))
        )

        # Track if we skip a video filter_complex so we can fix map references
        skipped_video_filter = False
        # Find what label the video filter creates (e.g., [1] from ...format=...[1])
        video_filter_output_label = None
        logger.info(f"[{job_id}] RAW PASSTHROUGH (plex): Processing {len(raw_args)} args")
        for i, arg in enumerate(raw_args):
            if arg == "-filter_complex" and i + 1 < len(raw_args):
                fc = raw_args[i + 1]
                logger.info(f"[{job_id}] Found filter_complex: {fc}")
                if "scale=" in fc and "format=" in fc:
                    # Extract output label like [1] from the end of the filter
                    match = re.search(r'(\[[0-9]+\])$', fc)
                    logger.info(f"[{job_id}] Regex match result: {match}")
                    if match:
                        video_filter_output_label = match.group(1)
                        logger.info(f"[{job_id}] Found video filter output label: {video_filter_output_label}")
                    else:
                        logger.warning(f"[{job_id}] Could not extract output label from filter!")

        filtered_args = []
        skip_next = False
        for i, arg in enumerate(raw_args):
            if skip_next:
                skip_next = False
                continue
            if arg in plex_opts_with_value:
                skip_next = True  # Skip this option and its value
                continue
            if arg in plex_opts_no_value:
                continue
            # Skip Plex's Linux VAAPI args (we add our own based on hw_accel setting)
            if "vaapi" in str(arg).lower() and hw_accel != "vaapi":
                continue
            # Replace libx264 with HW encoder if hardware acceleration is available
            # Downscale to 1080p max (community preference: don't transcode at 4K)
            if needs_hw_replace and arg in ("-codec:0", "-c:v") and i + 1 < len(raw_args) and raw_args[i + 1] == "libx264":
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
                    "-maxrate", "10M", "-bufsize", "5M"
                ])
                skip_next = True
                continue
            # Skip high bitrate settings from Plex (we use our own lower limits)
            if arg in ("-maxrate:0", "-bufsize:0", "-crf:0"):
                skip_next = True
                continue
            # Skip video scaling filter_complex (QSV doesn't need it, and it uses VAAPI format)
            if arg == "-filter_complex" and i + 1 < len(raw_args) and "scale=" in raw_args[i + 1] and "format=" in raw_args[i + 1]:
                logger.info(f"[{job_id}] SKIPPING filter_complex (VAAPI scale/format) - will need to fix map refs")
                skip_next = True
                skipped_video_filter = True
                continue
            # Fix map reference if we skipped video filter - replace [1] with 0:0
            if arg == "-map":
                next_arg = raw_args[i + 1] if i + 1 < len(raw_args) else "N/A"
                logger.info(f"[{job_id}] Found -map {next_arg}, skipped_video_filter={skipped_video_filter}, video_filter_output_label={video_filter_output_label}")
            if skipped_video_filter and arg == "-map" and i + 1 < len(raw_args) and video_filter_output_label:
                next_arg = raw_args[i + 1]
                if next_arg == video_filter_output_label:
                    logger.info(f"[{job_id}] Replacing -map {next_arg} with -map 0:0")
                    filtered_args.extend(["-map", "0:0"])
                    skip_next = True
                    continue
                else:
                    logger.info(f"[{job_id}] NOT replacing -map {next_arg} (doesn't match label {video_filter_output_label})")
            # Skip x264opts when using HW encoding (not compatible with QSV/NVENC)
            if hw_accel != "none" and arg.startswith("-x264opts"):
                skip_next = True
                continue
            # Skip -preset:0 when using HW encoding (x264/x265 option, not for VAAPI/QSV/NVENC)
            if hw_accel != "none" and arg == "-preset:0":
                skip_next = True
                continue
            # Replace Plex-specific codec names with standard ffmpeg equivalents
            if arg == "aac_lc":
                filtered_args.append("aac")
                continue
            # Rewrite Plex 'ochl' for old ffmpeg (<5.0) that only knows 'ocl'.
            # Modern ffmpeg (5.0+) supports 'ochl' natively, so only rewrite if needed.
            if "ochl=" in arg:
                import subprocess as _sp
                try:
                    ver = _sp.check_output([settings.ffmpeg_path, "-version"], stderr=_sp.DEVNULL).decode()
                    major = int(ver.split("version ")[1].split(".")[0])
                    if major < 5:
                        arg = arg.replace("ochl=", "ocl=")
                except Exception:
                    pass  # Keep ochl as-is if version check fails
            # Strip file: protocol prefix (safety: Jellyfin sends file:/path)
            if arg.startswith('file:"') and arg.endswith('"'):
                arg = arg[6:-1]
            elif arg.startswith("file:"):
                arg = arg[5:]
            # Apply all path mappings (longest prefix first)
            for frm, to in path_mappings:
                if arg.startswith(frm):
                    arg = to + arg[len(frm):]
                    break
            filtered_args.append(arg)

        # Inject VAAPI hardware acceleration args before -i
        # NOTE: Do NOT use -hwaccel_output_format vaapi — VGEM in WSL2 doesn't support
        # KMS dumb buffer allocation, so full hw decode->encode fails. Instead, decode on
        # CPU and use format=nv12,hwupload in -vf to upload frames for GPU encoding.
        if hw_accel == "vaapi" and needs_hw_replace:
            device = settings.qsv_device or "/dev/dri/renderD128"
            vaapi_init = ["-hwaccel", "vaapi", "-vaapi_device", device]
            for idx, a in enumerate(filtered_args):
                if a == "-i":
                    filtered_args[idx:idx] = vaapi_init
                    break

        return filtered_args

    def _filter_standard_args(self, raw_args: list[str]) -> list[str]:
        """
        Filter standard ffmpeg args (e.g., Jellyfin) for GPU worker execution.

        Handles: file: prefix stripping, path mappings, HW encoder replacement,
        QSV/NVENC/VAAPI init injection, and stripping of incompatible options.
        """
        path_mappings = settings.get_path_mappings()
        hw_accel = settings.hw_accel
        hw_encoder = settings.get_video_encoder()

        # Check if software encoding is requested (we'll replace with HW encoder)
        needs_hw_replace = hw_accel != "none" and any(
            raw_args[i] in ("-codec:v:0", "-codec:0", "-c:v", "-c:v:0", "-vcodec") and
            i + 1 < len(raw_args) and
            raw_args[i + 1] in ("libx264", "libx265")
            for i in range(len(raw_args))
        )

        filtered_args = []
        skip_next = False
        for i, arg in enumerate(raw_args):
            if skip_next:
                skip_next = False
                continue

            # Strip Jellyfin's file: protocol prefix
            if arg.startswith('file:"') and arg.endswith('"'):
                arg = arg[6:-1]
            elif arg.startswith("file:"):
                arg = arg[5:]

            # Replace software encoder with HW encoder
            if needs_hw_replace and arg in ("-codec:v:0", "-codec:0", "-c:v", "-c:v:0", "-vcodec"):
                next_arg = raw_args[i + 1] if i + 1 < len(raw_args) else ""
                if next_arg in ("libx264", "libx265"):
                    filtered_args.append(arg)
                    filtered_args.append(hw_encoder)
                    skip_next = True
                    continue

            # Strip x264opts (incompatible with HW encoders)
            if hw_accel != "none" and arg.startswith("-x264opts"):
                skip_next = True
                continue

            # Replace -crf with -global_quality for QSV
            if hw_accel == "qsv" and arg in ("-crf", "-crf:0"):
                filtered_args.append("-global_quality")
                continue

            # Strip -preset for VAAPI (doesn't support preset)
            if hw_accel == "vaapi" and arg in ("-preset", "-preset:0"):
                skip_next = True
                continue

            # Map x264 presets to valid QSV/NVENC presets
            if hw_accel in ("qsv", "nvenc") and i > 0 and raw_args[i - 1] in ("-preset", "-preset:0"):
                qsv_presets = {"ultrafast": "veryfast", "superfast": "veryfast"}
                if arg in qsv_presets:
                    arg = qsv_presets[arg]

            # Replace libfdk_aac with built-in aac (not all ffmpeg builds have libfdk)
            if arg == "libfdk_aac":
                arg = "aac"

            # Apply all path mappings (longest prefix first)
            for frm, to in path_mappings:
                if arg.startswith(frm):
                    arg = to + arg[len(frm):]
                    break
            filtered_args.append(arg)

        # Inject hardware acceleration init args before -i, but only if no
        # software-space -vf filters exist (they'd conflict with hwaccel output format).
        has_vf = any(a == "-vf" for a in filtered_args)
        if needs_hw_replace and not has_vf:
            hwaccel_args = []
            if hw_accel == "qsv":
                hwaccel_args = ["-hwaccel", "qsv"]
                if settings.qsv_device:
                    hwaccel_args.extend(["-qsv_device", settings.qsv_device])
                hwaccel_args.extend(["-hwaccel_output_format", "qsv"])
            elif hw_accel == "nvenc":
                hwaccel_args = ["-hwaccel", "cuda", "-hwaccel_output_format", "cuda"]
            elif hw_accel == "vaapi":
                device = settings.qsv_device or "/dev/dri/renderD128"
                hwaccel_args = ["-hwaccel", "vaapi", "-vaapi_device", device]

            if hwaccel_args:
                for idx, a in enumerate(filtered_args):
                    if a == "-i":
                        filtered_args[idx:idx] = hwaccel_args
                        break

        return filtered_args

    async def transcode(
        self,
        job: TranscodeJob,
        progress_callback: Optional[Callable[[TranscodeProgress], None]] = None
    ) -> bool:
        """Execute a transcode job."""
        # Use raw passthrough mode for Jellyfin (always) or Plex when output_path is empty.
        # Jellyfin sends complete ffmpeg commands; build_ffmpeg_command is only for Plex.
        use_raw = job.raw_args and (job.source != "plex" or not job.output_path or job.output_path == "")
        if use_raw:
            cmd = [self.ffmpeg_path, "-y", "-nostdin"]
            # Add progress reporting
            cmd.extend(["-progress", "pipe:1", "-stats_period", "0.5"])

            hw_accel = settings.hw_accel
            hw_encoder = settings.get_video_encoder()

            if job.source == "plex":
                filtered_args = self._filter_plex_args(job.job_id, job.raw_args, hw_accel, hw_encoder)
            else:
                filtered_args = self._filter_standard_args(job.raw_args)

            # Add error-level logging so we can see failures
            cmd.extend(["-loglevel", "error"])

            # If last arg is just "dash" or "hls", replace with proper output path
            if filtered_args and filtered_args[-1] in ("dash", "hls"):
                output_dir = Path(settings.temp_dir) / job.job_id
                output_dir.mkdir(parents=True, exist_ok=True)
                if filtered_args[-1] == "dash":
                    filtered_args[-1] = str(output_dir / "output.mpd")
                else:
                    filtered_args[-1] = str(output_dir / "output.m3u8")

            cmd.extend(filtered_args)
            logger.info(f"[{job.job_id}] Using RAW PASSTHROUGH mode (source={job.source})")
        else:
            cmd = self.build_ffmpeg_command(job)
        logger.info(f"[{job.job_id}] Starting transcode: {' '.join(cmd)}")

        # Ensure output directory exists (skip for raw passthrough mode)
        if job.output_path and job.output_path != "":
            output_dir = Path(job.output_path).parent
            output_dir.mkdir(parents=True, exist_ok=True)

        job.started_at = datetime.now()
        job.progress.status = "running"

        try:
            job.process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )

            # Parse progress from stdout
            async for progress in self._parse_progress(job):
                if progress_callback:
                    progress_callback(progress)

            # Wait for completion
            _, stderr = await job.process.communicate()

            job.completed_at = datetime.now()

            if job.process.returncode == 0:
                job.progress.status = "completed"
                job.progress.progress = 100.0
                logger.info(f"[{job.job_id}] Transcode completed successfully")
                return True
            else:
                job.progress.status = "failed"
                job.progress.error = stderr.decode()[-500:]  # Last 500 chars
                logger.error(f"[{job.job_id}] Transcode failed: {job.progress.error}")
                return False

        except asyncio.CancelledError:
            if job.process:
                job.process.terminate()
                await job.process.wait()
            job.progress.status = "cancelled"
            logger.info(f"[{job.job_id}] Transcode cancelled")
            raise
        except Exception as e:
            job.progress.status = "failed"
            job.progress.error = str(e)
            logger.exception(f"[{job.job_id}] Transcode error: {e}")
            return False

    async def _parse_progress(self, job: TranscodeJob) -> AsyncIterator[TranscodeProgress]:
        """Parse FFmpeg progress output."""
        if not job.process or not job.process.stdout:
            return

        buffer = ""
        async for line in job.process.stdout:
            buffer += line.decode()

            # Parse progress lines
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                self._update_progress_from_line(job.progress, line)

                # Yield progress on certain updates
                if line.startswith("progress=") or line.startswith("frame="):
                    yield job.progress

    def _update_progress_from_line(self, progress: TranscodeProgress, line: str) -> None:
        """Update progress from an FFmpeg output line."""
        if "=" not in line:
            return

        try:
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()

            if key == "frame":
                progress.frame = int(value)
            elif key == "fps":
                progress.fps = float(value) if value else 0.0
            elif key == "bitrate":
                progress.bitrate = value
            elif key == "total_size":
                progress.total_size = int(value) if value.isdigit() else 0
            elif key == "out_time_ms":
                progress.out_time_ms = int(value) if value.isdigit() else 0
            elif key == "speed":
                # Parse "1.5x" format
                match = re.match(r"([\d.]+)x?", value)
                if match:
                    progress.speed = float(match.group(1))
            elif key == "progress":
                if value == "end":
                    progress.progress = 100.0
                    progress.status = "completed"
        except (ValueError, IndexError):
            pass

    async def cancel(self, job: TranscodeJob) -> None:
        """Cancel a running transcode job."""
        if job.process and job.process.returncode is None:
            job.process.terminate()
            try:
                await asyncio.wait_for(job.process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                job.process.kill()
                await job.process.wait()
            job.progress.status = "cancelled"
            logger.info(f"[{job.job_id}] Job cancelled")


def parse_plex_args_to_job(
    job_id: str,
    raw_args: list[str],
    output_dir: Path,
    source: str = "plex"
) -> TranscodeJob:
    """
    Parse Plex transcoder arguments into a TranscodeJob.

    This maps the complex Plex arguments to our simplified job format.
    """
    job = TranscodeJob(
        job_id=job_id,
        input_path="",
        output_path=str(output_dir / "output.m3u8"),
        raw_args=raw_args,
        source=source
    )

    # Parse arguments
    i = 0
    while i < len(raw_args):
        arg = raw_args[i]

        if arg == "-i" and i + 1 < len(raw_args):
            job.input_path = raw_args[i + 1]
            i += 2
        elif arg in ("-c:v", "-codec:v", "-vcodec") and i + 1 < len(raw_args):
            job.video_codec = raw_args[i + 1]
            i += 2
        elif arg in ("-c:a", "-codec:a", "-acodec") and i + 1 < len(raw_args):
            job.audio_codec = raw_args[i + 1]
            i += 2
        elif arg in ("-b:v", "-maxrate:0") and i + 1 < len(raw_args):
            job.video_bitrate = raw_args[i + 1]
            i += 2
        elif arg in ("-b:a",) and i + 1 < len(raw_args):
            job.audio_bitrate = raw_args[i + 1]
            i += 2
        elif arg in ("-preset", "-preset:0") and i + 1 < len(raw_args):
            job.preset = raw_args[i + 1]
            i += 2
        elif arg == "-ss" and i + 1 < len(raw_args):
            try:
                job.seek = float(raw_args[i + 1])
            except ValueError:
                pass
            i += 2
        elif arg in ("-t", "-to") and i + 1 < len(raw_args):
            try:
                job.duration = float(raw_args[i + 1])
            except ValueError:
                pass
            i += 2
        elif arg in ("-hls_time", "-segment_time") and i + 1 < len(raw_args):
            try:
                job.segment_duration = int(raw_args[i + 1])
            except ValueError:
                pass
            i += 2
        elif arg == "-vf" and i + 1 < len(raw_args):
            job.filters.append(raw_args[i + 1])
            # Check for subtitle burn-in
            if "subtitle" in raw_args[i + 1].lower() or "ass=" in raw_args[i + 1]:
                job.subtitle_burn = True
            i += 2
        elif arg.endswith(".m3u8"):
            job.output_path = str(output_dir / Path(arg).name)
            job.output_type = "hls"
            i += 1
        elif arg.endswith(".mpd"):
            job.output_path = str(output_dir / Path(arg).name)
            job.output_type = "dash"
            i += 1
        else:
            i += 1

    return job


# Global transcoder instance
transcoder = FFmpegTranscoder()

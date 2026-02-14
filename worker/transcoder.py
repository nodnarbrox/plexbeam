"""
Plex Remote GPU Worker - FFmpeg Transcoder with Hardware Acceleration
"""
import asyncio
import json
import logging
import os
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
    callback_url: Optional[str] = None  # URL to reach media server from worker (beam mode)
    split_info: Optional[dict] = None   # Multi-GPU split info (worker_index, total_workers, ss, t)

    # Runtime state
    process: Optional[asyncio.subprocess.Process] = None
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    progress: TranscodeProgress = field(default_factory=lambda: TranscodeProgress(""))

    def __post_init__(self):
        self.progress = TranscodeProgress(self.job_id)


def _split_scale_args(body: str) -> list[str]:
    """Split scale filter args on ':' respecting parentheses nesting."""
    parts, current, depth = [], [], 0
    for ch in body:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        elif ch == ':' and depth == 0:
            parts.append(''.join(current))
            current = []
            continue
        current.append(ch)
    parts.append(''.join(current))
    return parts


def _convert_vf_to_gpu(vf_value: str, hw_accel: str) -> str | None:
    """Try to convert a software -vf filter chain to GPU equivalent.

    Returns the GPU filter string, or None if conversion isn't possible.
    Handles Jellyfin-style filters like:
      setparams=...,scale=trunc(...):trunc(...),format=yuv420p
    """
    # Bail out if subtitle burn-in present (CPU-only)
    if any(kw in vf_value for kw in ("subtitles=", "ass=", "overlay")):
        return None

    # Split on unescaped commas (Jellyfin uses \, for literal commas in expressions)
    filters = re.split(r'(?<!\\),', vf_value)
    scale_expr_w = None
    scale_expr_h = None

    for f in filters:
        f = f.strip()
        if f.startswith("scale="):
            scale_body = f[len("scale="):]
            parts = _split_scale_args(scale_body)
            if len(parts) >= 2:
                scale_expr_w = parts[0]
                scale_expr_h = parts[1]
            elif len(parts) == 1:
                scale_expr_w = parts[0]
                scale_expr_h = "-1"
        elif f.startswith("format=") or f.startswith("setparams="):
            continue  # Drop — absorbed by GPU scale or metadata-only
        else:
            return None  # Unknown filter, can't convert

    if scale_expr_w is None:
        return None  # No scale found, nothing to convert

    if hw_accel == "qsv":
        # scale_qsv doesn't support h=-2, use -1
        h = "-1" if scale_expr_h == "-2" else scale_expr_h
        return f"scale_qsv=w={scale_expr_w}:h={h}:format=nv12"
    elif hw_accel == "nvenc":
        h = "-1" if scale_expr_h == "-2" else scale_expr_h
        return f"scale_cuda={scale_expr_w}:{h}:format=nv12"
    elif hw_accel == "vaapi":
        # Use CPU scale + hwupload (some GPUs lack VAEntrypointVideoProc for scale_vaapi)
        return f"scale=w={scale_expr_w}:h={scale_expr_h}:flags=fast_bilinear,format=nv12,hwupload"
    return None


class FFmpegTranscoder:
    """Executes FFmpeg transcodes with hardware acceleration."""

    def __init__(self):
        self.ffmpeg_path = settings.ffmpeg_path
        self.ffprobe_path = settings.ffprobe_path
        self._ffmpeg_major = self._detect_ffmpeg_version()

    def _detect_ffmpeg_version(self) -> int:
        """Detect ffmpeg major version for compatibility handling."""
        try:
            result = subprocess.run(
                [self.ffmpeg_path, "-version"],
                capture_output=True, text=True, timeout=5
            )
            # Parse "ffmpeg version N.x..." or "ffmpeg version N.x.x-..."
            m = re.search(r'ffmpeg version (\d+)', result.stdout)
            if m:
                ver = int(m.group(1))
                logger.info(f"Detected ffmpeg major version: {ver}")
                return ver
        except Exception as e:
            logger.warning(f"Could not detect ffmpeg version: {e}")
        return 4  # assume old version as safe default

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
                "-global_quality", str(job.quality),
            ])
            if settings.qsv_low_power:
                cmd.extend(["-low_power", "1"])
            cmd.extend(["-async_depth", "1", "-extra_hw_frames", "8"])
            if job.video_bitrate:
                cmd.extend(["-b:v", job.video_bitrate])
        elif hw_accel == "nvenc":
            cmd.extend([
                "-preset", settings.nvenc_preset,
                "-tune", settings.nvenc_tune,
                "-rc", "constqp", "-qp", str(job.quality),
                "-rc-lookahead", "0", "-delay", "0",
                "-bf", "0", "-multipass", "disabled",
            ])
            if job.video_bitrate:
                cmd.extend(["-b:v", job.video_bitrate])
        elif hw_accel == "vaapi":
            cmd.extend(["-low_power", "1"])
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
                # QSV scale doesn't support h=-2, use explicit dims or -1
                h = "-1" if height in ("-2", "-1") else height
                cmd.extend(["-vf", f"scale_qsv=w={width}:h={h}:format=nv12"])
            elif hw_accel == "nvenc":
                h = "-1" if height in ("-2", "-1") else height
                cmd.extend(["-vf", f"scale_cuda={width}:{h}:format=nv12"])
            elif hw_accel == "vaapi":
                cmd.extend(["-vf", f"scale={width}:{height}:flags=fast_bilinear,format=nv12,hwupload"])
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

    def _extract_plex_info(self, raw_args: list[str]) -> dict:
        """Extract essential info from Plex's raw ffmpeg args.

        Instead of trying to fix Plex's complex command (VAAPI chains, tonemap,
        EAE options, etc.), we just extract the pieces we need and ignore the rest.
        """
        info = {
            'input_path': None,
            'seek': None,
            'duration': None,
            'start_at_zero': False,
            'copyts': False,
            'framerate': None,
            'keyframe_expr': None,
            'audio_filter': None,       # aresample filter_complex string
            'audio_streams': [],        # [{map, codec, bitrate, copypriorss}]
            'metadata': [],             # [(flag, value), ...]
            'output_format': None,      # "dash", "hls", etc.
            'output_path': None,
            'has_video': True,          # False for EAE audio-only
        }

        # Detect audio-only (EAE) vs video transcode.
        # -vn = explicit no video.  -eae_prefix:N = Plex Enhanced Audio Engine (audio-only).
        # Everything else has video — Plex sends h264_vaapi, libx264, etc. for transcodes.
        has_vn = '-vn' in raw_args
        has_eae = any(arg.startswith('-eae_prefix') for arg in raw_args)
        info['has_video'] = not has_vn and not has_eae

        # First pass: find audio filter output label
        audio_output_label = None
        for i, arg in enumerate(raw_args):
            if arg == '-filter_complex' and i + 1 < len(raw_args):
                fc = raw_args[i + 1]
                if 'aresample' in fc:
                    match = re.search(r'\[(\d+)\]$', fc)
                    if match:
                        audio_output_label = f"[{match.group(1)}]"

        # Second pass: extract everything
        map_count = 0
        i = 0
        while i < len(raw_args):
            arg = raw_args[i]
            nxt = raw_args[i + 1] if i + 1 < len(raw_args) else None

            if arg == '-i' and nxt:
                info['input_path'] = nxt
                i += 2
            elif arg == '-ss' and nxt:
                info['seek'] = nxt
                i += 2
            elif arg == '-t' and nxt:
                info['duration'] = nxt
                i += 2
            elif arg == '-start_at_zero':
                info['start_at_zero'] = True
                i += 1
            elif arg == '-copyts':
                info['copyts'] = True
                i += 1
            elif arg.startswith('-r:') and nxt:
                info['framerate'] = nxt
                i += 2
            elif arg.startswith('-force_key_frames:') and nxt:
                info['keyframe_expr'] = nxt
                i += 2
            elif arg == '-filter_complex' and nxt:
                if 'aresample' in nxt:
                    af = nxt
                    # Convert Plex hex stream IDs (#0xNN) to decimal for standard ffmpeg
                    af = re.sub(r'#0x([0-9a-fA-F]+)', lambda m: str(int(m.group(1), 16)), af)
                    # For beam-streamed chunks, the copy-remux only has v:0 + a:0,
                    # so absolute indices like [0:2] won't exist. Replace any
                    # [0:N] in aresample filter_complex with [0:a:0].
                    af = re.sub(r'\[0:\d+\]', '[0:a:0]', af, count=1)
                    # ffmpeg < 5 uses 'ocl', ffmpeg >= 5 uses 'ochl' (same as Plex)
                    if self._ffmpeg_major < 5:
                        af = af.replace('ochl=', 'ocl=')
                    info['audio_filter'] = af
                i += 2
            elif arg == '-map' and nxt:
                map_count += 1
                # Convert Plex hex stream IDs (#0xNN) to decimal
                map_val = re.sub(r'#0x([0-9a-fA-F]+)', lambda m: str(int(m.group(1), 16)), nxt)
                # For beam chunks: remap absolute audio index to relative
                # e.g. 0:2 -> 0:a:0 (copy-remux only has v:0 + a:0)
                if re.match(r'0:\d+$', map_val) and map_val != '0:0':
                    map_val = '0:a:0'
                # First -map is video (when video present) — skip, we use our own
                # BUT if it matches the audio filter output label, it's audio not video
                if info['has_video'] and map_count == 1 and map_val != audio_output_label:
                    i += 2
                    continue
                info['audio_streams'].append({
                    'map': map_val,
                    'codec': None,
                    'bitrate': None,
                    'copypriorss': None,
                })
                i += 2
            elif re.match(r'-codec:\d+', arg) and nxt:
                idx = int(arg.split(':')[1])
                audio_idx = idx - (1 if info['has_video'] else 0)
                if 0 <= audio_idx < len(info['audio_streams']):
                    info['audio_streams'][audio_idx]['codec'] = (
                        'aac' if nxt == 'aac_lc' else nxt
                    )
                i += 2
            elif re.match(r'-b:\d+', arg) and nxt:
                idx = int(arg.split(':')[1])
                audio_idx = idx - (1 if info['has_video'] else 0)
                if 0 <= audio_idx < len(info['audio_streams']):
                    info['audio_streams'][audio_idx]['bitrate'] = nxt
                i += 2
            elif re.match(r'-copypriorss:\d+', arg) and nxt:
                idx = int(arg.split(':')[1])
                audio_idx = idx - (1 if info['has_video'] else 0)
                if 0 <= audio_idx < len(info['audio_streams']):
                    info['audio_streams'][audio_idx]['copypriorss'] = nxt
                i += 2
            elif arg.startswith('-metadata:s:') and nxt:
                info['metadata'].append((arg, nxt))
                i += 2
            elif arg == '-f' and nxt:
                info['output_format'] = nxt
                i += 2
            else:
                i += 1

        # Last arg is the output path (e.g., "dash" or an absolute path)
        if raw_args:
            last = raw_args[-1]
            if not last.startswith('-'):
                info['output_path'] = last

        return info

    def _build_plex_command(self, job_id: str, raw_args: list[str], hw_accel: str, hw_encoder: str, callback_url: str = None, beam_stream: bool = False) -> list[str]:
        """Build clean ffmpeg args from Plex raw args.

        Instead of surgically fixing Plex's complex command (VAAPI tonemap chains,
        EAE options, hwaccel conflicts, filter_complex label mismatches, etc.),
        extract only what we need and build our own clean command.

        Video pipeline is 100% ours (scale + encode based on hw_accel setting).
        Audio pipeline preserves Plex's aresample filter with ochl→ocl fix.
        Everything else (Plex-specific options, VAAPI chains, tonemap) is ignored.
        """
        info = self._extract_plex_info(raw_args)
        path_mappings = settings.get_path_mappings()

        logger.info(f"[{job_id}] BUILD PLEX CMD: has_video={info['has_video']}, "
                     f"audio_streams={len(info['audio_streams'])}, "
                     f"seek={info['seek']}, beam_stream={beam_stream}")

        # Beam mode setup
        uploaded_input = settings.temp_dir / job_id / "input"
        beam_mode = beam_stream or uploaded_input.exists()
        beam_output_dir = settings.temp_dir / job_id if beam_mode else None
        if beam_mode:
            logger.info(f"[{job_id}] BEAM MODE: {'stream pipe' if beam_stream else 'uploaded file'}")

        parts = []

        # === HW ACCEL (before -i) ===
        if info['has_video']:
            if hw_accel == "qsv":
                parts.extend(["-hwaccel", "qsv"])
                if settings.qsv_device:
                    parts.extend(["-qsv_device", settings.qsv_device])
                parts.extend(["-hwaccel_output_format", "qsv", "-extra_hw_frames", "8"])
            elif hw_accel == "vaapi":
                device = settings.qsv_device or "/dev/dri/renderD128"
                parts.extend(["-hwaccel", "vaapi", "-vaapi_device", device])
            # nvenc: no hwaccel — CPU decode + hwupload_cuda in -vf
            # (M40/GM200 can't CUVID-decode HEVC Main 10)

        # === SEEK (before -i for files, after for pipes) ===
        if info['seek'] and not beam_stream:
            parts.extend(["-ss", info['seek']])

        # === INPUT ===
        if beam_mode:
            parts.extend(["-i", "pipe:0" if beam_stream else str(uploaded_input)])
        else:
            input_path = info['input_path'] or ""
            for frm, to in path_mappings:
                if input_path.startswith(frm):
                    input_path = to + input_path[len(frm):]
                    break
            parts.extend(["-i", input_path])

        # Deferred seek for pipe (output seeking — reliable for stdin)
        if info['seek'] and beam_stream:
            parts.extend(["-ss", info['seek']])
            logger.info(f"[{job_id}] BEAM: -ss {info['seek']} after -i (output seeking for pipe)")

        # Timestamps
        if info['start_at_zero']:
            parts.append("-start_at_zero")
        if info['copyts']:
            parts.append("-copyts")

        # Duration
        if info['duration']:
            parts.extend(["-t", info['duration']])

        parts.append("-y")

        # === VIDEO (entirely our pipeline) ===
        if info['has_video']:
            parts.extend(["-map", "0:v:0"])

            if hw_accel == "nvenc":
                vf = "scale=1920:-2:flags=fast_bilinear:sws_dither=none,format=nv12,hwupload_cuda"
                parts.extend(["-vf", vf, "-c:v", "h264_nvenc"])
                if beam_mode and settings.beam_max_bitrate:
                    parts.extend([
                        "-preset", "p1", "-tune", "ull",
                        "-rc", "cbr", "-b:v", settings.beam_max_bitrate,
                        "-rc-lookahead", "0", "-delay", "0",
                        "-bf", "0", "-multipass", "disabled",
                        "-forced-idr", "1", "-g", "24",
                        "-maxrate", settings.beam_max_bitrate,
                        "-bufsize", settings.beam_max_bitrate,
                    ])
                else:
                    parts.extend([
                        "-preset", "p1", "-tune", "ull",
                        "-rc", "constqp", "-qp", "25",
                        "-rc-lookahead", "0", "-delay", "0",
                        "-bf", "0", "-multipass", "disabled",
                        "-maxrate", "10M", "-bufsize", "5M",
                    ])
            elif hw_accel == "qsv":
                vf = "scale_qsv=w=1920:h=-1:format=nv12"
                parts.extend(["-vf", vf, "-c:v", "h264_qsv"])
                parts.extend([
                    "-preset", "veryfast", "-global_quality", "25",
                    "-low_power", "1", "-async_depth", "1",
                ])
            elif hw_accel == "vaapi":
                # CPU scale + hwupload (some GPUs lack VAEntrypointVideoProc for scale_vaapi)
                vf = "scale=1920:-2:flags=fast_bilinear,format=nv12,hwupload"
                parts.extend(["-vf", vf, "-c:v", "h264_vaapi", "-low_power", "1", "-qp", "25"])
            else:
                vf = "scale=1920:-2:flags=fast_bilinear:sws_dither=none"
                parts.extend(["-vf", vf, "-c:v", "libx264"])
                parts.extend(["-preset", "veryfast", "-crf", "25"])

            # Framerate from Plex
            if info['framerate']:
                parts.extend(["-r:0", info['framerate']])

            # Keyframes from Plex
            if info['keyframe_expr']:
                parts.extend(["-force_key_frames:0", info['keyframe_expr']])

        # === AUDIO (preserve Plex's aresample filter + stream settings) ===
        if info['audio_filter']:
            parts.extend(["-filter_complex", info['audio_filter']])

        for idx, audio in enumerate(info['audio_streams']):
            parts.extend(["-map", audio['map']])
            stream_idx = idx + (1 if info['has_video'] else 0)
            if audio.get('codec'):
                parts.extend([f"-codec:{stream_idx}", audio['codec']])
            if audio.get('bitrate'):
                parts.extend([f"-b:{stream_idx}", audio['bitrate']])
            if audio.get('copypriorss'):
                parts.extend([f"-copypriorss:{stream_idx}", audio['copypriorss']])

        # === METADATA ===
        for meta_flag, meta_val in info['metadata']:
            parts.extend([meta_flag, meta_val])

        # === OUTPUT FORMAT ===
        out_fmt = info['output_format'] or "dash"
        parts.extend(["-f", out_fmt])
        if out_fmt == "dash":
            parts.extend(["-dash_segment_type", "mp4"])
        parts.extend(["-avoid_negative_ts", "disabled"])
        parts.extend(["-map_metadata", "-1", "-map_chapters", "-1"])

        # Beam mode: inject short segments for low latency
        if beam_mode:
            parts.extend(["-seg_duration", "1"])

        # === OUTPUT PATH ===
        output_path = info['output_path']
        if beam_mode and beam_output_dir:
            beam_output_dir.mkdir(parents=True, exist_ok=True)
            name = Path(output_path).name if output_path else "dash"
            if name in ("dash", "hls", ""):
                name = "output.mpd" if out_fmt == "dash" else "output.m3u8"
            output_path = str(beam_output_dir / name)
            # DASH muxer writes segments relative to CWD.
            # Don't inject absolute -init_seg_name/-media_seg_name — ffmpeg 4.4.x
            # fails with absolute paths.  Instead, the caller sets cwd=beam_output_dir
            # so relative segment names land in the right directory.
            logger.info(f"[{job_id}] BEAM: output → {output_path}")
        elif not output_path:
            output_path = "dash"

        # Apply path mappings to output path (non-beam only)
        if not beam_mode:
            for frm, to in path_mappings:
                if output_path.startswith(frm):
                    output_path = to + output_path[len(frm):]
                    break

        parts.append(output_path)

        return parts

    def _filter_standard_args(self, raw_args: list[str], job_id: str = None, callback_url: str = None, beam_stream: bool = False) -> list[str]:
        """
        Filter standard ffmpeg args (e.g., Jellyfin) for GPU worker execution.

        Handles: file: prefix stripping, path mappings, HW encoder replacement,
        QSV/NVENC/VAAPI init injection, and stripping of incompatible options.
        """
        path_mappings = settings.get_path_mappings()
        hw_accel = settings.hw_accel
        hw_encoder = settings.get_video_encoder()

        # Beam mode: streaming pipe or uploaded file (no shared filesystem)
        uploaded_input = settings.temp_dir / job_id / "input" if job_id else None
        beam_mode = beam_stream or (uploaded_input is not None and uploaded_input.exists())
        beam_output_dir = settings.temp_dir / job_id if beam_mode else None
        if beam_mode:
            logger.info(f"[{job_id}] BEAM MODE (standard): {'stream pipe' if beam_stream else 'uploaded file'}")

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

            # Beam mode: replace input path
            if beam_mode and arg == "-i" and i + 1 < len(raw_args):
                filtered_args.append("-i")
                if beam_stream:
                    filtered_args.append("pipe:0")
                else:
                    filtered_args.append(str(uploaded_input))
                skip_next = True
                continue

            # Convert Jellyfin's SW video filters to GPU equivalents
            if arg == "-vf" and i + 1 < len(raw_args) and needs_hw_replace:
                gpu_vf = _convert_vf_to_gpu(raw_args[i + 1], hw_accel)
                if gpu_vf is not None:
                    filtered_args.extend(["-vf", gpu_vf])
                    skip_next = True
                    continue

            # Replace software encoder with HW encoder + inject speed flags
            if needs_hw_replace and arg in ("-codec:v:0", "-codec:0", "-c:v", "-c:v:0", "-vcodec"):
                next_arg = raw_args[i + 1] if i + 1 < len(raw_args) else ""
                if next_arg in ("libx264", "libx265"):
                    filtered_args.append(arg)
                    filtered_args.append(hw_encoder)
                    if hw_accel == "qsv":
                        if settings.qsv_low_power:
                            filtered_args.extend(["-low_power", "1"])
                        filtered_args.extend(["-async_depth", "1"])
                    elif hw_accel == "nvenc":
                        filtered_args.extend(["-tune", settings.nvenc_tune])
                    skip_next = True
                    continue

            # Strip x264opts (incompatible with HW encoders)
            if hw_accel != "none" and arg.startswith("-x264opts"):
                skip_next = True
                continue

            # Strip -maxrate/-bufsize for HW quality-based encoding.
            # Jellyfin sends very low maxrate (e.g. 292kbps) which is fine for
            # libx264 CRF (soft cap) but switches QSV/NVENC from quality mode
            # (ICQ/CQ) to VBR, severely limiting output quality.
            if needs_hw_replace and arg in ("-maxrate", "-bufsize"):
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

            # Replace HLS VOD mode with event mode — on Windows, VOD mode defers
            # m3u8 writing until ffmpeg exits, so killed jobs produce no playlist.
            # Event mode writes the m3u8 progressively as segments are produced.
            if arg == "vod" and i > 0 and raw_args[i - 1] == "-hls_playlist_type":
                arg = "event"

            # Apply all path mappings (longest prefix first) — skip in beam mode
            if not beam_mode:
                for frm, to in path_mappings:
                    if arg.startswith(frm):
                        arg = to + arg[len(frm):]
                        break
            filtered_args.append(arg)

        # Beam mode: redirect output path to worker temp dir
        if beam_mode and beam_output_dir and filtered_args:
            beam_output_dir.mkdir(parents=True, exist_ok=True)
            last = filtered_args[-1]
            if os.path.isabs(last) or last in ("dash", "hls"):
                name = Path(last).name
                if name == "dash":
                    name = "output.mpd"
                elif name == "hls":
                    name = "output.m3u8"
                filtered_args[-1] = str(beam_output_dir / name)
                logger.info(f"[{job_id}] BEAM: output redirected to {filtered_args[-1]}")

        # Beam mode: inject low-latency DASH muxer args for faster first-segment
        if beam_mode and filtered_args:
            output_path = filtered_args[-1]
            is_dash = output_path.endswith(".mpd") or (
                "-f" in filtered_args and filtered_args[filtered_args.index("-f") + 1] == "dash"
            ) if "-f" in filtered_args else output_path.endswith(".mpd")
            if is_dash:
                dash_args = ["-seg_duration", "1"]
                filtered_args[-1:] = dash_args + [filtered_args[-1]]
                logger.info(f"[{job_id}] BEAM: injected low-latency DASH args (1s segments)")

        # Inject hardware acceleration init args before -i.
        # Only inject when no software filters exist — QSV decode to system memory
        # fails on some platforms (Windows) when combined with SW -vf filters.
        if needs_hw_replace:
            hw_filter_keywords = ("scale_qsv", "scale_cuda", "scale_vaapi", "hwupload", "hwupload_cuda")
            has_sw_filter = False
            for idx, a in enumerate(filtered_args):
                if a in ("-vf", "-filter_complex") and idx + 1 < len(filtered_args):
                    fval = filtered_args[idx + 1]
                    if not any(kw in fval for kw in hw_filter_keywords):
                        has_sw_filter = True
                        break
            if not has_sw_filter:
                hwaccel_args = []
                if hw_accel == "qsv":
                    hwaccel_args = ["-hwaccel", "qsv"]
                    if settings.qsv_device:
                        hwaccel_args.extend(["-qsv_device", settings.qsv_device])
                    hwaccel_args.extend(["-hwaccel_output_format", "qsv",
                                         "-extra_hw_frames", "8"])
                elif hw_accel == "nvenc":
                    hwaccel_args = ["-hwaccel", "cuda",
                                    "-hwaccel_output_format", "cuda"]
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
            # Maximize CPU decode parallelism
            cmd.extend(["-threads", "0", "-thread_type", "frame"])
            # Add progress reporting
            cmd.extend(["-progress", "pipe:1", "-stats_period", "0.5"])

            hw_accel = settings.hw_accel
            hw_encoder = settings.get_video_encoder()

            if job.source == "plex":
                filtered_args = self._build_plex_command(job.job_id, job.raw_args, hw_accel, hw_encoder, callback_url=job.callback_url)
            else:
                filtered_args = self._filter_standard_args(job.raw_args, job_id=job.job_id, callback_url=job.callback_url)

            # Add error-level logging so we can see failures
            cmd.extend(["-loglevel", "error"])

            # If last arg is just "dash" or "hls" (relative), replace with temp path.
            # If it's an absolute path (cartridge resolved CWD), use it directly and
            # ensure the parent directory exists.
            if filtered_args:
                last_arg = filtered_args[-1]
                if last_arg in ("dash", "hls"):
                    output_dir = Path(settings.temp_dir).resolve() / job.job_id
                    output_dir.mkdir(parents=True, exist_ok=True)
                    if last_arg == "dash":
                        filtered_args[-1] = str(output_dir / "output.mpd")
                    else:
                        filtered_args[-1] = str(output_dir / "output.m3u8")
                    # DASH muxer writes segments relative to CWD.
                    # Don't inject absolute -init_seg_name/-media_seg_name —
                    # ffmpeg 4.4.x fails with absolute paths in these options.
                    # Instead, set cwd to output_dir when launching the process.
                    job._output_dir = output_dir
                elif os.path.isabs(last_arg) or (len(last_arg) > 2 and last_arg[1] == ':'):
                    # Absolute path — ensure parent directory exists
                    Path(last_arg).parent.mkdir(parents=True, exist_ok=True)

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
            # Use output_dir as cwd so DASH segments land in the right place
            # (ffmpeg 4.4.x doesn't support absolute paths in -init_seg_name)
            proc_cwd = str(getattr(job, '_output_dir', None) or '.') if hasattr(job, '_output_dir') and job._output_dir else None
            job.process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=proc_cwd
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

    def build_beam_stream_command(self, job: TranscodeJob) -> list[str]:
        """Build ffmpeg command for beam streaming (input from stdin pipe)."""
        cmd = [self.ffmpeg_path, "-y"]
        # Maximize CPU decode parallelism (4K HEVC decode is the bottleneck)
        cmd.extend(["-threads", "0", "-thread_type", "frame"])
        # Minimal probe for fastest pipe startup (MKV header is <10KB, 50KB is plenty)
        # analyzeduration=0: trust container headers, don't buffer input
        cmd.extend(["-probesize", "50000", "-analyzeduration", "0"])
        cmd.extend(["-progress", "pipe:1", "-stats_period", "0.5"])

        hw_accel = settings.hw_accel
        hw_encoder = settings.get_video_encoder()

        # Filter args with beam_stream=True (replaces -i path with pipe:0)
        if job.source == "plex":
            filtered = self._build_plex_command(
                job.job_id, job.raw_args, hw_accel, hw_encoder,
                callback_url=job.callback_url, beam_stream=True
            )
        else:
            filtered = self._filter_standard_args(
                job.raw_args, job_id=job.job_id,
                callback_url=job.callback_url, beam_stream=True
            )

        cmd.extend(["-loglevel", "error"])

        # Handle relative output paths (same as transcode())
        # Store output_dir on the job so the caller can set cwd
        if filtered:
            last_arg = filtered[-1]
            if last_arg in ("dash", "hls"):
                output_dir = settings.temp_dir / job.job_id
                output_dir.mkdir(parents=True, exist_ok=True)
                if last_arg == "dash":
                    filtered[-1] = str(output_dir / "output.mpd")
                else:
                    filtered[-1] = str(output_dir / "output.m3u8")
                job._output_dir = output_dir
            elif os.path.isabs(last_arg) or (len(last_arg) > 2 and last_arg[1] == ':'):
                output_dir = Path(last_arg).parent
                output_dir.mkdir(parents=True, exist_ok=True)
                job._output_dir = output_dir

        cmd.extend(filtered)
        return cmd

    async def read_beam_progress(self, job: TranscodeJob) -> None:
        """Read and update progress from ffmpeg stdout (progress pipe)."""
        if not job.process or not job.process.stdout:
            return

        buffer = ""
        try:
            async for line in job.process.stdout:
                buffer += line.decode()
                while "\n" in buffer:
                    line_str, buffer = buffer.split("\n", 1)
                    self._update_progress_from_line(job.progress, line_str)
        except Exception:
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

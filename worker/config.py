"""
PlexBeam GPU Worker - Configuration
"""
import os
from pathlib import Path
from typing import Optional, Literal
from pydantic import Field
from pydantic_settings import BaseSettings


class WorkerSettings(BaseSettings):
    """Configuration for the GPU worker service."""

    # Server settings
    host: str = Field(default="0.0.0.0", description="Host to bind to")
    port: int = Field(default=8765, description="Port to listen on")
    workers: int = Field(default=1, description="Number of uvicorn workers")

    # FFmpeg settings
    ffmpeg_path: str = Field(
        default="ffmpeg",
        description="Path to FFmpeg executable"
    )
    ffprobe_path: str = Field(
        default="ffprobe",
        description="Path to FFprobe executable"
    )

    # Hardware acceleration
    hw_accel: Literal["qsv", "nvenc", "vaapi", "none"] = Field(
        default="qsv",
        description="Hardware acceleration type"
    )

    # Intel QSV specific settings
    qsv_device: Optional[str] = Field(
        default=None,
        description="QSV device path (e.g., /dev/dri/renderD128 on Linux)"
    )
    qsv_preset: str = Field(
        default="veryfast",
        description="QSV encoding preset"
    )
    qsv_quality: int = Field(
        default=25,
        ge=1,
        le=51,
        description="QSV global quality (lower = better)"
    )
    qsv_low_power: bool = Field(
        default=True,
        description="Use VDBOX fixed-function encode (faster, ~same quality)"
    )

    # NVIDIA specific settings
    nvenc_preset: str = Field(
        default="p1",
        description="NVENC preset (p1-p7, p1=fastest)"
    )
    nvenc_tune: str = Field(
        default="ull",
        description="NVENC tuning: hq, ll (low latency), ull (ultra-low latency)"
    )
    nvenc_gpu: int = Field(
        default=0,
        description="NVENC GPU index"
    )
    nvenc_hwdecode: bool = Field(
        default=False,
        description="Use NVDEC hardware decode (auto-detected at startup for Turing+ GPUs)"
    )

    # Paths
    temp_dir: Path = Field(
        default=Path("./transcode_temp"),
        description="Temporary directory for transcode output"
    )
    log_dir: Path = Field(
        default=Path("./logs"),
        description="Directory for worker logs"
    )

    # Shared storage (for outputting segments that Plex reads)
    shared_output_dir: Optional[Path] = Field(
        default=None,
        description="Shared directory where Plex can read output segments (SMB/NFS mount)"
    )

    # Media path mapping (for bare-metal workers where Plex container paths differ)
    # Maps container path prefix to host path prefix.
    # Example: PLEX_WORKER_MEDIA_PATH_FROM=/media  PLEX_WORKER_MEDIA_PATH_TO=C:/Users/me/media
    media_path_from: Optional[str] = Field(
        default=None,
        description="Container media path prefix to replace (e.g., /media)"
    )
    media_path_to: Optional[str] = Field(
        default=None,
        description="Host media path to replace with (e.g., C:/Users/me/plex-remote/config/media)"
    )

    # Multiple path mappings (semicolon-delimited from=to pairs)
    # Supplements media_path_from/to. Use for mapping additional container paths.
    # Example: PLEX_WORKER_PATH_MAPPINGS="/config=C:/Users/me/config/jellyfin;/tmp=C:/temp"
    path_mappings: Optional[str] = Field(
        default=None,
        description="Additional path mappings as semicolon-delimited from=to pairs"
    )

    # Job settings
    max_concurrent_jobs: int = Field(
        default=2,
        description="Maximum concurrent transcode jobs"
    )
    job_timeout: int = Field(
        default=3600,
        description="Default job timeout in seconds"
    )
    segment_timeout: int = Field(
        default=30,
        description="Timeout for individual segment generation"
    )

    # Network settings
    plex_server_url: Optional[str] = Field(
        default=None,
        description="Plex server URL for fetching media (e.g., http://192.168.1.100:32400)"
    )

    # Beam mode (remote workers without shared filesystem)
    beam_max_bitrate: Optional[str] = Field(
        default=None,
        description="Max video bitrate for beam mode output (e.g., '4M'). "
                    "Caps output to fit bandwidth-limited networks like WiFi."
    )

    # Cleanup
    cleanup_temp_after_hours: int = Field(
        default=24,
        description="Delete temp files older than this many hours"
    )

    # Logging
    log_level: str = Field(
        default="INFO",
        description="Log level (DEBUG, INFO, WARNING, ERROR)"
    )
    log_ffmpeg_output: bool = Field(
        default=True,
        description="Log FFmpeg stderr output"
    )

    # Authentication (optional)
    api_key: Optional[str] = Field(
        default=None,
        description="API key for authenticating requests from cartridge"
    )

    class Config:
        env_prefix = "PLEX_WORKER_"
        env_file = ".env"
        env_file_encoding = "utf-8"

    def get_path_mappings(self) -> list[tuple[str, str]]:
        """Get all path mappings (from, to) sorted longest-prefix-first."""
        mappings = []
        if self.media_path_from and self.media_path_to:
            mappings.append((self.media_path_from, self.media_path_to))
        if self.path_mappings:
            for pair in self.path_mappings.split(";"):
                pair = pair.strip()
                if "=" in pair:
                    frm, to = pair.split("=", 1)
                    mappings.append((frm.strip(), to.strip()))
        # Sort longest prefix first so /config/cache matches before /config
        mappings.sort(key=lambda m: len(m[0]), reverse=True)
        return mappings

    def get_ffmpeg_hwaccel_args(self) -> list[str]:
        """Get FFmpeg hardware acceleration arguments based on settings."""
        if self.hw_accel == "qsv":
            args = ["-hwaccel", "qsv", "-hwaccel_output_format", "qsv"]
            if self.qsv_device:
                args.extend(["-init_hw_device", f"qsv=qsv:hw,child_device={self.qsv_device}"])
            return args
        elif self.hw_accel == "nvenc":
            return ["-hwaccel", "cuda", "-hwaccel_output_format", "cuda"]
        elif self.hw_accel == "vaapi":
            device = self.qsv_device or "/dev/dri/renderD128"
            return ["-hwaccel", "vaapi", "-vaapi_device", device]
        else:
            return []

    def get_video_encoder(self) -> str:
        """Get the video encoder name based on hw_accel setting."""
        encoders = {
            "qsv": "h264_qsv",
            "nvenc": "h264_nvenc",
            "vaapi": "h264_vaapi",
            "none": "libx264"
        }
        return encoders.get(self.hw_accel, "libx264")

    def get_hevc_encoder(self) -> str:
        """Get the HEVC encoder name based on hw_accel setting."""
        encoders = {
            "qsv": "hevc_qsv",
            "nvenc": "hevc_nvenc",
            "vaapi": "hevc_vaapi",
            "none": "libx265"
        }
        return encoders.get(self.hw_accel, "libx265")


# Global settings instance
settings = WorkerSettings()


def init_directories():
    """Create necessary directories.

    Resolves temp_dir/log_dir to absolute paths so that subprocess cwd
    doesn't cause ffmpeg to write segments to doubly-nested relative paths.
    """
    settings.temp_dir = settings.temp_dir.resolve()
    settings.log_dir = settings.log_dir.resolve()
    settings.temp_dir.mkdir(parents=True, exist_ok=True)
    settings.log_dir.mkdir(parents=True, exist_ok=True)
    if settings.shared_output_dir:
        settings.shared_output_dir.mkdir(parents=True, exist_ok=True)

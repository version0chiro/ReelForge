from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple

import numpy as np

from .core import FeatureSample, Highlight, VideoSource


StatusCallback = Optional[Callable[[str, float], None]]
ANALYSIS_FPS = 4.0
ANALYSIS_WIDTH = 160
ANALYSIS_HEIGHT = 90
AUDIO_RATE = 8_000
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi"}


class FFmpegError(RuntimeError):
    pass


def _creation_flags() -> int:
    return getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0


def find_tool(name: str) -> str:
    executable = f"{name}.exe" if os.name == "nt" else name
    candidates = []
    if getattr(sys, "frozen", False):
        bundle_root = Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
        candidates.extend(
            [
                bundle_root / executable,
                Path(sys.executable).parent / executable,
                bundle_root / "ffmpeg" / executable,
            ]
        )
    package_root = Path(__file__).resolve().parents[1]
    candidates.extend(
        [
            package_root / "vendor" / executable,
            package_root.parent / "vendor" / executable,
        ]
    )
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    located = shutil.which(name) or shutil.which(executable)
    if located:
        return located
    raise FFmpegError(
        f"{name} was not found. Use the packaged ReelForge release or install FFmpeg and add it to PATH."
    )


def _run_json(command: Sequence[str]) -> dict:
    completed = subprocess.run(
        list(command),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_creation_flags(),
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or "FFprobe could not read the file."
        raise FFmpegError(message)
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise FFmpegError("FFprobe returned invalid metadata.") from exc


def _parse_rate(value: str) -> float:
    try:
        numerator, denominator = value.split("/", 1)
        denominator_value = float(denominator)
        return float(numerator) / denominator_value if denominator_value else 0.0
    except (AttributeError, ValueError, ZeroDivisionError):
        return 0.0


def probe_video(path: Path) -> VideoSource:
    payload = _run_json(
        [
            find_tool("ffprobe"),
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=codec_type,width,height,avg_frame_rate,r_frame_rate",
            "-of",
            "json",
            str(path),
        ]
    )
    streams = payload.get("streams", [])
    video = next(
        (stream for stream in streams if stream.get("codec_type") == "video"), None
    )
    if video is None:
        raise FFmpegError(f"No readable video track was found in {path.name}.")
    try:
        duration = float(payload.get("format", {}).get("duration", 0.0))
        width = int(video.get("width", 0))
        height = int(video.get("height", 0))
    except (TypeError, ValueError) as exc:
        raise FFmpegError(f"Invalid video metadata in {path.name}.") from exc
    if duration <= 0 or width <= 0 or height <= 0:
        raise FFmpegError(f"Incomplete video metadata in {path.name}.")
    frame_rate = _parse_rate(video.get("avg_frame_rate", "0/1"))
    if frame_rate <= 0:
        frame_rate = _parse_rate(video.get("r_frame_rate", "0/1"))
    has_audio = any(stream.get("codec_type") == "audio" for stream in streams)
    return VideoSource(
        path=path,
        name=path.name,
        duration=duration,
        width=width,
        height=height,
        frame_rate=frame_rate,
        has_audio=has_audio,
    )


def _read_exact(stream, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = stream.read(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _process_error(process: subprocess.Popen, fallback: str) -> None:
    stderr = process.stderr.read() if process.stderr is not None else b""
    return_code = process.wait()
    if return_code != 0:
        if isinstance(stderr, bytes):
            message = stderr.decode("utf-8", errors="replace").strip()
        else:
            message = str(stderr).strip()
        raise FFmpegError(message or fallback)


def _visual_features(path: Path) -> List[Tuple[float, float, float]]:
    process = subprocess.Popen(
        [
            find_tool("ffmpeg"),
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-an",
            "-vf",
            (
                f"fps={ANALYSIS_FPS},"
                f"scale={ANALYSIS_WIDTH}:{ANALYSIS_HEIGHT}:flags=fast_bilinear,"
                "format=gray"
            ),
            "-f",
            "rawvideo",
            "-pix_fmt",
            "gray",
            "pipe:1",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        creationflags=_creation_flags(),
    )
    if process.stdout is None:
        process.kill()
        raise FFmpegError("FFmpeg could not open its analysis stream.")

    frame_size = ANALYSIS_WIDTH * ANALYSIS_HEIGHT
    previous_frame = None
    previous_histogram = None
    features: List[Tuple[float, float, float]] = []
    while True:
        raw = _read_exact(process.stdout, frame_size)
        if len(raw) != frame_size:
            break
        frame = np.frombuffer(raw, dtype=np.uint8).reshape(
            (ANALYSIS_HEIGHT, ANALYSIS_WIDTH)
        )
        histogram, _ = np.histogram(frame, bins=16, range=(0, 256))
        histogram = histogram.astype(np.float32)
        histogram /= max(1.0, float(histogram.sum()))

        motion = 0.0
        scene = 0.0
        crop_x = 0.5
        if previous_frame is not None:
            difference = np.abs(
                frame.astype(np.int16) - previous_frame.astype(np.int16)
            ).astype(np.float32)
            motion = float(difference.mean() / 255.0)
            threshold = max(12.0, float(np.percentile(difference, 84)))
            weights = np.where(difference >= threshold, difference, 0.0)
            column_weights = weights.sum(axis=0)
            weight_sum = float(column_weights.sum())
            if weight_sum > 0:
                crop_x = float(
                    np.dot(
                        column_weights,
                        np.arange(ANALYSIS_WIDTH, dtype=np.float32),
                    )
                    / weight_sum
                    / (ANALYSIS_WIDTH - 1)
                )
        if previous_histogram is not None:
            scene = float(np.abs(histogram - previous_histogram).sum() * 0.5)
        features.append((motion, scene, min(0.92, max(0.08, crop_x))))
        previous_frame = frame.copy()
        previous_histogram = histogram

    _process_error(process, f"Visual analysis failed for {path.name}.")
    return features


def _audio_features(path: Path) -> List[Tuple[float, float]]:
    process = subprocess.Popen(
        [
            find_tool("ffmpeg"),
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-vn",
            "-ac",
            "1",
            "-ar",
            str(AUDIO_RATE),
            "-acodec",
            "pcm_f32le",
            "-f",
            "f32le",
            "pipe:1",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        creationflags=_creation_flags(),
    )
    if process.stdout is None:
        process.kill()
        raise FFmpegError("FFmpeg could not open its audio analysis stream.")

    samples_per_window = max(1, int(AUDIO_RATE / ANALYSIS_FPS))
    bytes_per_window = samples_per_window * 4
    features: List[Tuple[float, float]] = []
    previous_rms = 0.0
    while True:
        raw = _read_exact(process.stdout, bytes_per_window)
        if not raw:
            break
        usable_size = len(raw) - (len(raw) % 4)
        if usable_size <= 0:
            break
        samples = np.frombuffer(raw[:usable_size], dtype="<f4")
        rms = float(math.sqrt(float(np.mean(np.square(samples, dtype=np.float64)))))
        onset = max(0.0, rms - previous_rms)
        features.append((rms, onset))
        previous_rms = rms
        if len(raw) < bytes_per_window:
            break

    _process_error(process, f"Audio analysis failed for {path.name}.")
    return features


def analyze_video(path: Path, status: StatusCallback = None) -> VideoSource:
    source = probe_video(path)
    if status:
        status(f"Reading motion in {source.name}", 0.05)
    visual = _visual_features(path)
    audio: List[Tuple[float, float]] = []
    if source.has_audio:
        if status:
            status(f"Reading sound in {source.name}", 0.55)
        audio = _audio_features(path)

    sample_count = max(len(visual), len(audio))
    if sample_count == 0:
        raise FFmpegError(f"No decodable frames were found in {source.name}.")
    samples: List[FeatureSample] = []
    for index in range(sample_count):
        motion, scene, crop_x = (
            visual[index] if index < len(visual) else (0.0, 0.0, 0.5)
        )
        rms, onset = audio[index] if index < len(audio) else (0.0, 0.0)
        samples.append(
            FeatureSample(
                time=min(source.duration, index / ANALYSIS_FPS),
                audio_rms=rms,
                audio_onset=onset,
                motion=motion,
                scene=scene,
                crop_x=crop_x,
            )
        )
    source.samples = samples
    if status:
        status(f"Signals ready for {source.name}", 1.0)
    return source


def _video_filter(
    index: int, source: VideoSource, highlight: Highlight, framing: str
) -> List[str]:
    duration = max(0.1, highlight.duration)
    use_fit = framing == "fit" or (
        framing == "adaptive" and source.width / max(1, source.height) > 0.82
    )
    if not use_fit:
        return [
            (
                f"[{index}:v]fps=30,"
                "scale=1080:1920:force_original_aspect_ratio=increase:flags=lanczos,"
                f"crop=1080:1920:x='max(0,min(iw-ow,(iw-ow)*{highlight.crop_x:.5f}))':"
                "y='max(0,(ih-oh)/2)',"
                "setsar=1,unsharp=5:5:0.45:5:5:0,"
                f"trim=duration={duration:.5f},setpts=PTS-STARTPTS,"
                f"format=yuv420p[v{index}]"
            )
        ]

    return [
        f"[{index}:v]fps=30,split=2[bg{index}][fg{index}]",
        (
            f"[bg{index}]"
            "scale=1080:1920:force_original_aspect_ratio=increase:flags=lanczos,"
            "crop=1080:1920,setsar=1,gblur=sigma=34,"
            f"eq=brightness=-0.13:saturation=1.12[bgx{index}]"
        ),
        (
            f"[fg{index}]"
            "scale=1080:1920:force_original_aspect_ratio=decrease:flags=lanczos,"
            f"setsar=1,unsharp=5:5:0.45:5:5:0[fgx{index}]"
        ),
        (
            f"[bgx{index}][fgx{index}]"
            "overlay=(W-w)/2:(H-h)/2,"
            f"trim=duration={duration:.5f},setpts=PTS-STARTPTS,"
            f"format=yuv420p[v{index}]"
        ),
    ]


def build_filter_graph(
    sources: Sequence[VideoSource],
    highlights: Sequence[Highlight],
    framing: str = "adaptive",
) -> str:
    if not highlights:
        raise FFmpegError("No selected sequences are available to export.")
    filters: List[str] = []
    concat_inputs = []
    for index, highlight in enumerate(highlights):
        source = sources[highlight.source_index]
        filters.extend(_video_filter(index, source, highlight, framing))
        duration = max(0.1, highlight.duration)
        if source.has_audio:
            filters.append(
                (
                    f"[{index}:a]aresample=48000,"
                    "aformat=sample_fmts=fltp:channel_layouts=stereo,"
                    f"apad,atrim=duration={duration:.5f},"
                    f"asetpts=PTS-STARTPTS[a{index}]"
                )
            )
        else:
            filters.append(
                (
                    "anullsrc=channel_layout=stereo:sample_rate=48000,"
                    f"atrim=duration={duration:.5f},"
                    f"asetpts=PTS-STARTPTS[a{index}]"
                )
            )
        concat_inputs.append(f"[v{index}][a{index}]")
    filters.append(
        "".join(concat_inputs)
        + f"concat=n={len(highlights)}:v=1:a=1[vout][aout]"
    )
    return ";".join(filters)


def render_reel(
    sources: Sequence[VideoSource],
    highlights: Sequence[Highlight],
    output: Path,
    framing: str = "adaptive",
    status: StatusCallback = None,
) -> Path:
    if not highlights:
        raise FFmpegError("Scan the videos before exporting a Reel.")
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [find_tool("ffmpeg"), "-y", "-nostdin", "-hide_banner", "-loglevel", "error"]
    for highlight in highlights:
        source = sources[highlight.source_index]
        command.extend(
            [
                "-ss",
                f"{highlight.start:.5f}",
                "-t",
                f"{highlight.duration:.5f}",
                "-i",
                str(source.path),
            ]
        )
    command.extend(
        [
            "-filter_complex",
            build_filter_graph(sources, highlights, framing),
            "-map",
            "[vout]",
            "-map",
            "[aout]",
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "17",
            "-maxrate",
            "24M",
            "-bufsize",
            "48M",
            "-pix_fmt",
            "yuv420p",
            "-r",
            "30",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-movflags",
            "+faststart",
            "-progress",
            "pipe:1",
            "-nostats",
            str(output),
        ]
    )

    total_duration = sum(item.duration for item in highlights)
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_creation_flags(),
    )
    if process.stdout is None:
        process.kill()
        raise FFmpegError("FFmpeg could not start the export.")
    for line in process.stdout:
        key, _, value = line.strip().partition("=")
        if key in {"out_time_us", "out_time_ms"}:
            try:
                microseconds = float(value)
                progress = min(0.99, microseconds / 1_000_000 / total_duration)
                if status:
                    status("Rendering enhanced 1080x1920 Reel", progress)
            except (ValueError, ZeroDivisionError):
                pass
    stderr = process.stderr.read() if process.stderr is not None else ""
    return_code = process.wait()
    if return_code != 0:
        if output.exists():
            output.unlink()
        raise FFmpegError(stderr.strip() or "FFmpeg could not render the Reel.")
    if not output.is_file() or output.stat().st_size == 0:
        raise FFmpegError("The export finished without producing a video.")
    if status:
        status("Reel export complete", 1.0)
    return output

from __future__ import annotations

import math
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple


def clamp(value: float, minimum: float = 0.0, maximum: float = 1.0) -> float:
    return min(maximum, max(minimum, value))


def percentile(values: Iterable[float], quantile: float) -> float:
    ordered = sorted(value for value in values if math.isfinite(value))
    if not ordered:
        return 0.0
    if len(ordered) == 1:
        return ordered[0]
    position = clamp(quantile) * (len(ordered) - 1)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def normalize(values: Sequence[float]) -> List[float]:
    if not values:
        return []
    low = percentile(values, 0.2)
    high = percentile(values, 0.92)
    maximum = max((value for value in values if math.isfinite(value)), default=low)
    if high - low < 1e-9 and maximum - low >= 1e-9:
        high = maximum
    span = high - low
    if not math.isfinite(span) or span < 1e-9:
        return [0.0 for _ in values]
    return [clamp((value - low) / span) for value in values]


@dataclass
class FeatureSample:
    time: float
    audio_rms: float = 0.0
    audio_onset: float = 0.0
    motion: float = 0.0
    scene: float = 0.0
    crop_x: float = 0.5


@dataclass
class ScoredSample:
    sample: FeatureSample
    audio_score: float
    motion_score: float
    scene_score: float
    visual_score: float
    score: float


@dataclass
class VideoSource:
    path: Path
    name: str
    duration: float
    width: int
    height: int
    frame_rate: float
    has_audio: bool
    samples: List[FeatureSample] = field(default_factory=list)

    @property
    def resolution_label(self) -> str:
        return f"{self.width}x{self.height}"


@dataclass
class Highlight:
    source_index: int
    source_name: str
    start: float
    end: float
    peak: float
    score: float
    peak_score: float
    sequence_strength: float
    crop_x: float
    reasons: Tuple[str, ...]

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


@dataclass
class DetectionSettings:
    target_duration: float = 15.0
    sequence_duration: float = 3.5
    audio_weight: float = 0.55
    sensitivity: float = 0.58
    hook_first: bool = True


def score_samples(
    samples: Sequence[FeatureSample], audio_weight: float
) -> List[ScoredSample]:
    rms = normalize([sample.audio_rms for sample in samples])
    onset = normalize([sample.audio_onset for sample in samples])
    motion = normalize([sample.motion for sample in samples])
    scene = normalize([sample.scene for sample in samples])
    has_audio = any(value > 0.02 for value in rms + onset)
    has_visual = any(value > 0.02 for value in motion + scene)
    effective_audio_weight = clamp(audio_weight)
    if not has_audio and has_visual:
        effective_audio_weight = 0.0
    elif has_audio and not has_visual:
        effective_audio_weight = 1.0

    scored: List[ScoredSample] = []
    for index, sample in enumerate(samples):
        audio = clamp(rms[index] * 0.62 + onset[index] * 0.38)
        visual = clamp(motion[index] * 0.7 + scene[index] * 0.3)
        synergy = min(audio, visual) * 0.12
        scored.append(
            ScoredSample(
                sample=sample,
                audio_score=audio,
                motion_score=motion[index],
                scene_score=scene[index],
                visual_score=visual,
                score=clamp(
                    audio * effective_audio_weight
                    + visual * (1.0 - effective_audio_weight)
                    + synergy
                ),
            )
        )
    return scored


def detect_highlights(
    sources: Sequence[VideoSource], settings: DetectionSettings
) -> List[Highlight]:
    valid_sources = [
        (index, source)
        for index, source in enumerate(sources)
        if source.samples and source.duration > 0
    ]
    if not valid_sources:
        return []

    sequence_duration = clamp(settings.sequence_duration, 1.0, 8.0)
    target_duration = clamp(settings.target_duration, 3.0, 60.0)
    desired_count = max(1, int(math.ceil(target_duration / sequence_duration)))
    candidates: List[Highlight] = []

    for source_index, source in valid_sources:
        scored = score_samples(source.samples, settings.audio_weight)
        candidates.extend(
            _candidates(
                source=source,
                source_index=source_index,
                scored=scored,
                desired_count=desired_count,
                settings=settings,
            )
        )

    ranked = sorted(candidates, key=lambda item: item.score, reverse=True)
    selected: List[Highlight] = []
    selected_keys = set()

    def append(candidate: Highlight) -> None:
        key = (
            candidate.source_index,
            round(candidate.start, 4),
            round(candidate.end, 4),
        )
        if len(selected) < desired_count and key not in selected_keys:
            selected.append(candidate)
            selected_keys.add(key)

    if desired_count >= len(valid_sources):
        for source_index, _ in valid_sources:
            best = next(
                (item for item in ranked if item.source_index == source_index), None
            )
            if best is not None:
                append(best)
    for candidate in ranked:
        append(candidate)

    selected.sort(key=lambda item: (item.source_index, item.start))
    if settings.hook_first and len(selected) > 1:
        hook = max(selected, key=lambda item: item.score)
        selected.remove(hook)
        diverse = [hook]
        seen_sources = {hook.source_index}
        while selected:
            next_index = next(
                (
                    index
                    for index, item in enumerate(selected)
                    if item.source_index not in seen_sources
                ),
                0,
            )
            item = selected.pop(next_index)
            diverse.append(item)
            seen_sources.add(item.source_index)
        selected = diverse

    trimmed: List[Highlight] = []
    used_duration = 0.0
    for candidate in selected:
        remaining = target_duration - used_duration
        if remaining <= 0:
            break
        item = candidate
        if item.duration > remaining:
            item = replace(item, end=item.start + remaining)
        if item.duration >= 0.5:
            trimmed.append(item)
            used_duration += item.duration
    return trimmed


def _candidates(
    source: VideoSource,
    source_index: int,
    scored: Sequence[ScoredSample],
    desired_count: int,
    settings: DetectionSettings,
) -> List[Highlight]:
    if not scored:
        return []
    clip_duration = clamp(settings.sequence_duration, 1.0, 8.0)
    if source.duration <= settings.target_duration + 0.15:
        peak = max(scored, key=lambda item: item.score)
        metrics = _sequence_metrics(scored, peak, source.duration)
        return [
            _make_highlight(
                source,
                source_index,
                0.0,
                source.duration,
                peak,
                metrics,
                scored,
                source.duration,
            )
        ]

    average_step = (
        max(0.02, source.duration / (len(scored) - 1))
        if len(scored) > 1
        else clip_duration
    )
    peak_radius = max(1, int(round((clip_duration * 0.42) / average_step)))
    threshold = 0.7 - clamp(settings.sensitivity) * 0.36
    local_peaks = []

    for index, item in enumerate(scored):
        lower = max(0, index - peak_radius)
        upper = min(len(scored) - 1, index + peak_radius)
        if all(
            other_index == index or scored[other_index].score <= item.score
            for other_index in range(lower, upper + 1)
        ):
            metrics = _sequence_metrics(scored, item, clip_duration)
            local_peaks.append((item, metrics))

    local_peaks.sort(
        key=lambda pair: (pair[1][0] >= threshold, pair[1][0]), reverse=True
    )
    selected: List[Highlight] = []
    minimum_gap = min(1.0, clip_duration * 0.3)

    for peak, metrics in local_peaks:
        start = clamp(
            peak.sample.time - clip_duration * 0.46,
            0.0,
            max(0.0, source.duration - clip_duration),
        )
        end = min(source.duration, start + clip_duration)
        if end - start < clip_duration and start > 0:
            start = max(0.0, end - clip_duration)
        if any(
            start < item.end + minimum_gap and end > item.start - minimum_gap
            for item in selected
        ):
            continue
        selected.append(
            _make_highlight(
                source,
                source_index,
                start,
                end,
                peak,
                metrics,
                scored,
                clip_duration,
            )
        )
        if len(selected) >= desired_count:
            break

    if not selected:
        peak = max(scored, key=lambda item: item.score)
        metrics = _sequence_metrics(scored, peak, clip_duration)
        start = clamp(
            peak.sample.time - clip_duration * 0.46,
            0.0,
            max(0.0, source.duration - clip_duration),
        )
        selected.append(
            _make_highlight(
                source,
                source_index,
                start,
                min(source.duration, start + clip_duration),
                peak,
                metrics,
                scored,
                clip_duration,
            )
        )
    return selected


def _sequence_metrics(
    scored: Sequence[ScoredSample], peak: ScoredSample, duration: float
) -> Tuple[float, float, float]:
    start = peak.sample.time - duration * 0.46
    end = peak.sample.time + duration * 0.54
    window = [
        item for item in scored if start <= item.sample.time <= end
    ] or [peak]
    scores = [item.score for item in window]
    sustained = percentile(scores, 0.68)
    average = sum(scores) / len(scores)
    synergy = sum(min(item.audio_score, item.visual_score) for item in window) / len(
        window
    )
    sequence_score = clamp(
        peak.score * 0.55 + sustained * 0.25 + average * 0.12 + synergy * 0.08
    )
    return sequence_score, peak.score, sustained


def _make_highlight(
    source: VideoSource,
    source_index: int,
    start: float,
    end: float,
    peak: ScoredSample,
    metrics: Tuple[float, float, float],
    scored: Sequence[ScoredSample],
    clip_duration: float,
) -> Highlight:
    radius = max(0.5, clip_duration * 0.7)
    nearby = [
        item
        for item in scored
        if abs(item.sample.time - peak.sample.time) <= radius
    ]
    total_weight = 0.0
    weighted_crop = 0.0
    for item in nearby:
        proximity = 1.0 - abs(item.sample.time - peak.sample.time) / radius
        weight = max(0.05, item.motion_score) * max(0.0, proximity)
        weighted_crop += item.sample.crop_x * weight
        total_weight += weight
    crop_x = (
        clamp(weighted_crop / total_weight, 0.08, 0.92)
        if total_weight > 0
        else 0.5
    )

    reasons = []
    if peak.audio_score >= 0.52:
        reasons.append("sound")
    if peak.motion_score >= 0.52:
        reasons.append("motion")
    if peak.scene_score >= 0.58:
        reasons.append("scene")
    if not reasons:
        reasons = [
            max(
                (
                    ("sound", peak.audio_score),
                    ("motion", peak.motion_score),
                    ("scene", peak.scene_score),
                ),
                key=lambda pair: pair[1],
            )[0]
        ]

    return Highlight(
        source_index=source_index,
        source_name=source.name,
        start=start,
        end=end,
        peak=peak.sample.time,
        score=metrics[0],
        peak_score=metrics[1],
        sequence_strength=metrics[2],
        crop_x=crop_x,
        reasons=tuple(reasons),
    )

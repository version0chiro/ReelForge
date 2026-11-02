export function clamp(value, min = 0, max = 1) {
  return Math.min(max, Math.max(min, value));
}
export function percentile(values, quantile) {
  const finite = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (finite.length === 0) return 0;
  if (finite.length === 1) return finite[0];

  const index = clamp(quantile, 0, 1) * (finite.length - 1);
  const lower = Math.floor(index);
  const upper = Math.ceil(index);
  const weight = index - lower;
  return finite[lower] * (1 - weight) + finite[upper] * weight;
}

export function normalizeRobust(values) {
  if (values.length === 0) return [];
  const low = percentile(values, 0.2);
  let high = percentile(values, 0.92);
  const maximum = Math.max(...values.filter(Number.isFinite));
  if (high - low < 1e-9 && maximum - low >= 1e-9) high = maximum;
  const range = high - low;

  if (!Number.isFinite(range) || range < 1e-9) {
    return values.map(() => 0);
  }

  return values.map((value) => clamp((value - low) / range));
}

export function computeAudioEnvelope(audioBuffer, bucketSeconds = 0.1) {
  if (!audioBuffer || audioBuffer.length === 0 || audioBuffer.sampleRate <= 0) {
    return [];
  }

  const channelCount = Math.max(1, audioBuffer.numberOfChannels);
  const bucketSize = Math.max(1, Math.floor(audioBuffer.sampleRate * bucketSeconds));
  const bucketCount = Math.ceil(audioBuffer.length / bucketSize);
  const result = [];
  let previousRms = 0;
  let previousPeak = 0;

  for (let bucket = 0; bucket < bucketCount; bucket += 1) {
    const start = bucket * bucketSize;
    const end = Math.min(audioBuffer.length, start + bucketSize);
    const stride = Math.max(1, Math.floor((end - start) / 512));
    let squareSum = 0;
    let sampleCount = 0;
    let peak = 0;

    for (let channel = 0; channel < channelCount; channel += 1) {
      const samples = audioBuffer.getChannelData(channel);
      for (let index = start; index < end; index += stride) {
        const magnitude = Math.abs(samples[index] || 0);
        squareSum += magnitude * magnitude;
        peak = Math.max(peak, magnitude);
        sampleCount += 1;
      }
    }

    const rms = Math.sqrt(squareSum / Math.max(1, sampleCount));
    const onset = Math.max(0, rms - previousRms * 0.9)
      + Math.max(0, peak - previousPeak) * 0.3;

    result.push({
      time: Math.min(audioBuffer.duration, (start + (end - start) / 2) / audioBuffer.sampleRate),
      rms,
      onset,
    });

    previousRms = rms;
    previousPeak = peak;
  }

  return result;
}

function interpolateSeries(series, time, key) {
  if (!series.length) return 0;
  if (time <= series[0].time) return Number(series[0][key]) || 0;
  if (time >= series[series.length - 1].time) {
    return Number(series[series.length - 1][key]) || 0;
  }

  let low = 0;
  let high = series.length - 1;
  while (low + 1 < high) {
    const middle = Math.floor((low + high) / 2);
    if (series[middle].time <= time) low = middle;
    else high = middle;
  }

  const before = series[low];
  const after = series[high];
  const span = Math.max(1e-9, after.time - before.time);
  const progress = clamp((time - before.time) / span);
  const from = Number(before[key]) || 0;
  const to = Number(after[key]) || 0;
  return from + (to - from) * progress;
}

export function mergeFeatureSamples(visualSamples, audioSamples, duration) {
  let timeBase = audioSamples.length
    ? audioSamples.map(({ time }) => ({ time }))
    : visualSamples;

  if (!timeBase.length && duration > 0) {
    timeBase = [{ time: duration / 2, motion: 0, scene: 0, cropX: 0.5 }];
  }

  return timeBase.map((sample) => ({
    time: clamp(sample.time, 0, duration),
    motion: visualSamples.length
      ? interpolateSeries(visualSamples, sample.time, "motion")
      : Number(sample.motion) || 0,
    scene: visualSamples.length
      ? interpolateSeries(visualSamples, sample.time, "scene")
      : Number(sample.scene) || 0,
    cropX: visualSamples.length
      ? clamp(interpolateSeries(visualSamples, sample.time, "cropX") || 0.5, 0, 1)
      : clamp(Number(sample.cropX) || 0.5, 0, 1),
    audioRms: interpolateSeries(audioSamples, sample.time, "rms"),
    audioOnset: interpolateSeries(audioSamples, sample.time, "onset"),
  }));
}

export function scoreFeatureSamples(samples, options = {}) {
  const audioWeight = clamp(Number(options.audioWeight ?? 0.55));
  const rms = normalizeRobust(samples.map((sample) => sample.audioRms));
  const onset = normalizeRobust(samples.map((sample) => sample.audioOnset));
  const motion = normalizeRobust(samples.map((sample) => sample.motion));
  const scene = normalizeRobust(samples.map((sample) => sample.scene));
  const hasAudio = rms.some((value) => value > 0.02) || onset.some((value) => value > 0.02);
  const hasVisual = motion.some((value) => value > 0.02) || scene.some((value) => value > 0.02);

  let effectiveAudioWeight = audioWeight;
  if (!hasAudio && hasVisual) effectiveAudioWeight = 0;
  if (hasAudio && !hasVisual) effectiveAudioWeight = 1;

  return samples.map((sample, index) => {
    const audioScore = clamp(rms[index] * 0.62 + onset[index] * 0.38);
    const visualScore = clamp(motion[index] * 0.7 + scene[index] * 0.3);
    const synergy = Math.min(audioScore, visualScore) * 0.12;
    const score = clamp(
      audioScore * effectiveAudioWeight
      + visualScore * (1 - effectiveAudioWeight)
      + synergy,
    );

    return {
      ...sample,
      audioScore,
      motionScore: motion[index],
      sceneScore: scene[index],
      visualScore,
      score,
    };
  });
}

function overlapSeconds(first, second) {
  return Math.max(0, Math.min(first.end, second.end) - Math.max(first.start, second.start));
}

function weightedCropAt(samples, center, radius) {
  let totalWeight = 0;
  let weightedX = 0;

  for (const sample of samples) {
    const distance = Math.abs(sample.time - center);
    if (distance > radius) continue;
    const proximity = 1 - distance / Math.max(radius, 1e-6);
    const weight = Math.max(0.05, sample.motionScore) * proximity;
    weightedX += sample.cropX * weight;
    totalWeight += weight;
  }

  return totalWeight > 0 ? clamp(weightedX / totalWeight, 0.08, 0.92) : 0.5;
}

function reasonsFor(sample) {
  const reasons = [];
  if (sample.audioScore >= 0.52) reasons.push("sound");
  if (sample.motionScore >= 0.52) reasons.push("motion");
  if (sample.sceneScore >= 0.58) reasons.push("scene");

  if (reasons.length === 0) {
    const strongest = [
      ["sound", sample.audioScore],
      ["motion", sample.motionScore],
      ["scene", sample.sceneScore],
    ].sort((a, b) => b[1] - a[1])[0];
    reasons.push(strongest[0]);
  }

  return reasons;
}

function sequenceMetrics(scored, candidate, clipDuration) {
  const start = candidate.time - clipDuration * 0.46;
  const end = candidate.time + clipDuration * 0.54;
  const windowSamples = scored.filter((sample) => sample.time >= start && sample.time <= end);
  const usable = windowSamples.length ? windowSamples : [candidate];
  const scores = usable.map((sample) => sample.score);
  const sustained = percentile(scores, 0.68);
  const average = scores.reduce((sum, score) => sum + score, 0) / scores.length;
  const synergy = usable.reduce(
    (sum, sample) => sum + Math.min(sample.audioScore, sample.visualScore),
    0,
  ) / usable.length;

  return {
    score: clamp(
      candidate.score * 0.55
      + sustained * 0.25
      + average * 0.12
      + synergy * 0.08,
    ),
    peakScore: candidate.score,
    sequenceStrength: sustained,
  };
}

export function detectHighlights(samples, options = {}) {
  const duration = Math.max(0, Number(options.duration) || 0);
  const targetDuration = clamp(Number(options.targetDuration) || 15, 3, Math.max(3, duration || 60));
  const clipDuration = clamp(Number(options.clipDuration) || 2.5, 1, 8);
  const sensitivity = clamp(Number(options.sensitivity ?? 0.58));
  const orderMode = options.orderMode === "chronological" ? "chronological" : "hook";
  const scored = scoreFeatureSamples(samples, options);

  if (duration <= 0 || scored.length === 0) return [];
  if (duration <= targetDuration + 0.15) {
    const peak = scored.reduce((best, sample) => sample.score > best.score ? sample : best, scored[0]);
    const metrics = sequenceMetrics(scored, peak, duration);
    return [{
      id: "clip-1",
      start: 0,
      end: duration,
      peak: peak.time,
      ...metrics,
      cropX: weightedCropAt(scored, peak.time, Math.max(1, duration / 3)),
      cropMode: "auto",
      reasons: reasonsFor(peak),
    }];
  }

  const averageStep = scored.length > 1
    ? Math.max(0.02, duration / (scored.length - 1))
    : clipDuration;
  const peakRadius = Math.max(1, Math.round((clipDuration * 0.42) / averageStep));
  const threshold = 0.7 - sensitivity * 0.36;
  const localPeaks = [];

  for (let index = 0; index < scored.length; index += 1) {
    const sample = scored[index];
    let isPeak = true;
    for (
      let neighbor = Math.max(0, index - peakRadius);
      neighbor <= Math.min(scored.length - 1, index + peakRadius);
      neighbor += 1
    ) {
      if (neighbor !== index && scored[neighbor].score > sample.score) {
        isPeak = false;
        break;
      }
    }

    if (isPeak) localPeaks.push(sample);
  }

  const candidates = localPeaks
    .map((sample) => ({ ...sample, ...sequenceMetrics(scored, sample, clipDuration) }))
    .sort((a, b) => b.score - a.score)
    .sort((a, b) => {
      const aPasses = a.score >= threshold;
      const bPasses = b.score >= threshold;
      if (aPasses !== bPasses) return aPasses ? -1 : 1;
      return b.score - a.score;
    });

  const desiredCount = Math.max(1, Math.ceil(targetDuration / clipDuration));
  const selected = [];
  const minimumGap = Math.min(1, clipDuration * 0.3);

  for (const candidate of candidates) {
    let start = clamp(candidate.time - clipDuration * 0.46, 0, Math.max(0, duration - clipDuration));
    let end = Math.min(duration, start + clipDuration);
    if (end - start < clipDuration && start > 0) start = Math.max(0, end - clipDuration);

    const proposed = { start, end };
    const collides = selected.some((clip) => (
      overlapSeconds(clip, proposed) > 0
      || (
        proposed.start < clip.end + minimumGap
        && proposed.end > clip.start - minimumGap
      )
    ));
    if (collides) continue;

    selected.push({
      id: `clip-${selected.length + 1}-${Math.round(candidate.time * 1000)}`,
      start,
      end,
      peak: candidate.time,
      score: candidate.score,
      peakScore: candidate.peakScore,
      sequenceStrength: candidate.sequenceStrength,
      cropX: weightedCropAt(scored, candidate.time, clipDuration * 0.7),
      cropMode: "auto",
      reasons: reasonsFor(candidate),
    });

    if (selected.length >= desiredCount) break;
  }

  if (selected.length === 0) {
    const fallback = scored.reduce((best, sample) => sample.score > best.score ? sample : best, scored[0]);
    const metrics = sequenceMetrics(scored, fallback, clipDuration);
    const start = clamp(fallback.time - clipDuration * 0.46, 0, Math.max(0, duration - clipDuration));
    selected.push({
      id: `clip-1-${Math.round(fallback.time * 1000)}`,
      start,
      end: Math.min(duration, start + clipDuration),
      peak: fallback.time,
      ...metrics,
      cropX: fallback.cropX,
      cropMode: "auto",
      reasons: reasonsFor(fallback),
    });
  }

  selected.sort((a, b) => a.start - b.start);
  if (orderMode === "hook" && selected.length > 1) {
    const hookIndex = selected.reduce(
      (bestIndex, clip, index) => clip.score > selected[bestIndex].score ? index : bestIndex,
      0,
    );
    const [hook] = selected.splice(hookIndex, 1);
    selected.unshift(hook);
  }

  let accumulated = 0;
  for (const clip of selected) {
    const remaining = targetDuration - accumulated;
    if (remaining <= 0) {
      clip.end = clip.start;
      continue;
    }
    if (clip.end - clip.start > remaining) clip.end = clip.start + remaining;
    accumulated += clip.end - clip.start;
  }

  return selected
    .filter((clip) => clip.end - clip.start >= 0.5)
    .map((clip, index) => ({ ...clip, id: `clip-${index + 1}-${Math.round(clip.peak * 1000)}` }));
}

export function detectHighlightsAcrossSources(sources, options = {}) {
  const validSources = sources
    .map((source, sourceIndex) => ({ ...source, sourceIndex: source.sourceIndex ?? sourceIndex }))
    .filter((source) => source.samples?.length && Number(source.duration) > 0);
  if (!validSources.length) return [];

  const targetDuration = clamp(Number(options.targetDuration) || 15, 3, 60);
  const clipDuration = clamp(Number(options.clipDuration) || 3.5, 1, 8);
  const desiredCount = Math.max(1, Math.ceil(targetDuration / clipDuration));
  const orderMode = options.orderMode === "chronological" ? "chronological" : "hook";
  const allCandidates = [];

  for (const source of validSources) {
    const candidateTarget = Math.min(
      source.duration,
      Math.max(clipDuration, desiredCount * clipDuration),
    );
    const candidates = detectHighlights(source.samples, {
      ...options,
      duration: source.duration,
      targetDuration: candidateTarget,
      clipDuration,
      orderMode: "chronological",
    });

    for (const clip of candidates) {
      allCandidates.push({
        ...clip,
        sourceIndex: source.sourceIndex,
        sourceId: source.id ?? `source-${source.sourceIndex + 1}`,
        sourceName: source.name ?? `Source ${source.sourceIndex + 1}`,
      });
    }
  }

  const ranked = [...allCandidates].sort((a, b) => b.score - a.score);
  const selected = [];
  const selectedIds = new Set();
  const add = (clip) => {
    const key = `${clip.sourceId}:${clip.start.toFixed(4)}:${clip.end.toFixed(4)}`;
    if (selectedIds.has(key) || selected.length >= desiredCount) return;
    selectedIds.add(key);
    selected.push({ ...clip });
  };

  if (desiredCount >= validSources.length) {
    for (const source of validSources) {
      const best = ranked.find((clip) => clip.sourceIndex === source.sourceIndex);
      if (best) add(best);
    }
  }

  for (const clip of ranked) add(clip);

  selected.sort((a, b) => (
    a.sourceIndex - b.sourceIndex
    || a.start - b.start
  ));
  if (orderMode === "hook" && selected.length > 1) {
    const hookIndex = selected.reduce(
      (bestIndex, clip, index) => clip.score > selected[bestIndex].score ? index : bestIndex,
      0,
    );
    const [hook] = selected.splice(hookIndex, 1);
    selected.unshift(hook);
  }

  let accumulated = 0;
  for (const clip of selected) {
    const remaining = targetDuration - accumulated;
    if (remaining <= 0) {
      clip.end = clip.start;
      continue;
    }
    if (clip.end - clip.start > remaining) clip.end = clip.start + remaining;
    accumulated += clip.end - clip.start;
  }

  return selected
    .filter((clip) => clip.end - clip.start >= 0.5)
    .map((clip, index) => ({
      ...clip,
      id: `clip-${index + 1}-${clip.sourceIndex + 1}-${Math.round(clip.peak * 1000)}`,
    }));
}

export function interpolateCrop(samples, time, fallback = 0.5) {
  if (!samples.length) return clamp(fallback, 0, 1);
  return clamp(interpolateSeries(samples, time, "cropX") || fallback, 0, 1);
}

export function stabilizeCropSamples(samples, options = {}) {
  if (samples.length < 2) return samples.map((sample) => ({ ...sample }));
  const radius = Math.max(1, Math.round(Number(options.radius) || 3));
  const maxStep = clamp(Number(options.maxStep) || 0.055, 0.01, 0.3);
  const centerSnap = clamp(Number(options.centerSnap) || 0.055, 0, 0.2);
  let previous = clamp(samples[0].cropX || 0.5, 0.08, 0.92);

  return samples.map((sample, index) => {
    let totalWeight = 0;
    let weightedX = 0;
    const start = Math.max(0, index - radius);
    const end = Math.min(samples.length - 1, index + radius);

    for (let neighbor = start; neighbor <= end; neighbor += 1) {
      const candidate = samples[neighbor];
      const distanceWeight = 1 - Math.abs(neighbor - index) / (radius + 1);
      const motionWeight = 0.35 + clamp(candidate.motion || 0, 0, 1);
      const weight = distanceWeight * motionWeight;
      weightedX += clamp(candidate.cropX || 0.5, 0.08, 0.92) * weight;
      totalWeight += weight;
    }

    let desired = totalWeight > 0 ? weightedX / totalWeight : 0.5;
    if (Math.abs(desired - 0.5) <= centerSnap) desired = 0.5;
    const sceneAllowsJump = (sample.scene || 0) >= 0.82;
    const allowedStep = sceneAllowsJump ? Math.max(maxStep, 0.18) : maxStep;
    const stabilized = clamp(
      previous + clamp(desired - previous, -allowedStep, allowedStep),
      0.08,
      0.92,
    );
    previous = stabilized;
    return { ...sample, cropX: stabilized };
  });
}

export function formatTime(seconds, includeTenths = true) {
  const safe = Math.max(0, Number(seconds) || 0);
  const minutes = Math.floor(safe / 60);
  const wholeSeconds = Math.floor(safe % 60);
  const tenths = Math.floor((safe % 1) * 10);
  return `${minutes}:${String(wholeSeconds).padStart(2, "0")}${includeTenths ? `.${tenths}` : ""}`;
}

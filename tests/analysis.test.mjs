import test from "node:test";
import assert from "node:assert/strict";
import {
  computeAudioEnvelope,
  detectHighlights,
  formatTime,
  mergeFeatureSamples,
  normalizeRobust,
  percentile,
  scoreFeatureSamples,
  stabilizeCropSamples,
} from "../src/analysis.js";

test("percentile and robust normalization tolerate outliers", () => {
  assert.equal(percentile([0, 10, 20], 0.5), 10);
  const normalized = normalizeRobust([1, 1, 2, 3, 100]);
  assert.equal(normalized.length, 5);
  assert.equal(normalized[0], 0);
  assert.equal(normalized.at(-1), 1);
});

test("audio envelope finds an abrupt loud moment", () => {
  const samples = new Float32Array(1_000);
  samples.fill(0.01);
  samples.fill(0.9, 500, 600);
  const fakeBuffer = {
    length: samples.length,
    sampleRate: 1_000,
    numberOfChannels: 1,
    duration: 1,
    getChannelData: () => samples,
  };

  const envelope = computeAudioEnvelope(fakeBuffer, 0.1);
  const loudest = envelope.reduce((best, item) => item.rms > best.rms ? item : best);
  const strongestOnset = envelope.reduce((best, item) => item.onset > best.onset ? item : best);
  assert.ok(loudest.time >= 0.5 && loudest.time <= 0.6);
  assert.ok(strongestOnset.time >= 0.5 && strongestOnset.time <= 0.6);
});

test("sound and motion spikes become separate highlight clips", () => {
  const samples = Array.from({ length: 81 }, (_, index) => {
    const time = index * 0.5;
    return {
      time,
      audioRms: time === 8 ? 1 : 0.05,
      audioOnset: time === 8 ? 1 : 0,
      motion: time === 28 ? 1 : 0.03,
      scene: time === 28 ? 0.8 : 0.01,
      cropX: time === 28 ? 0.8 : 0.5,
    };
  });

  const clips = detectHighlights(samples, {
    duration: 40,
    targetDuration: 8,
    clipDuration: 4,
    audioWeight: 0.5,
    sensitivity: 0.6,
  });

  assert.equal(clips.length, 2);
  assert.ok(clips.some((clip) => clip.start <= 8 && clip.end >= 8));
  assert.ok(clips.some((clip) => clip.start <= 28 && clip.end >= 28));
  assert.ok(clips.reduce((sum, clip) => sum + clip.end - clip.start, 0) <= 8.001);
});

test("feature scoring falls back to visuals when audio is unavailable", () => {
  const scored = scoreFeatureSamples([
    { time: 0, audioRms: 0, audioOnset: 0, motion: 0, scene: 0, cropX: 0.5 },
    { time: 1, audioRms: 0, audioOnset: 0, motion: 1, scene: 1, cropX: 0.5 },
  ], { audioWeight: 1 });

  assert.ok(scored[1].score > scored[0].score);
});

test("audio and visual samples merge while preserving audio timing", () => {
  const merged = mergeFeatureSamples(
    [{ time: 0.5, motion: 0.2, scene: 0.1, cropX: 0.7 }],
    [{ time: 0, rms: 0 }, { time: 1, rms: 1 }],
    1,
  );
  assert.equal(merged.length, 2);
  assert.equal(merged[1].audioRms, 1);
  assert.equal(merged[0].cropX, 0.7);
});

test("short videos remain a single clip", () => {
  const clips = detectHighlights([
    { time: 2, audioRms: 1, audioOnset: 1, motion: 1, scene: 0, cropX: 0.5 },
  ], { duration: 5, targetDuration: 15, clipDuration: 3 });
  assert.deepEqual([clips[0].start, clips[0].end], [0, 5]);
});

test("hook-first order opens with the strongest selected moment", () => {
  const samples = Array.from({ length: 61 }, (_, index) => {
    const time = index * 0.5;
    return {
      time,
      audioRms: time === 5 ? 0.7 : time === 24 ? 1 : 0,
      audioOnset: time === 5 ? 0.7 : time === 24 ? 1 : 0,
      motion: time === 5 ? 0.5 : time === 24 ? 1 : 0,
      scene: 0,
      cropX: 0.5,
    };
  });
  const clips = detectHighlights(samples, {
    duration: 30,
    targetDuration: 6,
    clipDuration: 3,
    orderMode: "hook",
  });
  assert.ok(clips[0].peak > clips[1].peak);
  assert.ok(clips[0].score >= clips[1].score);
});

test("crop stabilization suppresses jitter while allowing a scene jump", () => {
  const stabilized = stabilizeCropSamples([
    { time: 0, cropX: 0.48, motion: 0.2, scene: 0 },
    { time: 1, cropX: 0.56, motion: 0.3, scene: 0 },
    { time: 2, cropX: 0.47, motion: 0.2, scene: 0 },
    { time: 3, cropX: 0.9, motion: 1, scene: 1 },
  ], { radius: 1, maxStep: 0.05 });

  assert.ok(Math.abs(stabilized[1].cropX - stabilized[0].cropX) <= 0.051);
  assert.ok(stabilized[3].cropX - stabilized[2].cropX > 0.05);
});

test("time formatting is suitable for trim controls", () => {
  assert.equal(formatTime(65.29), "1:05.2");
  assert.equal(formatTime(5, false), "0:05");
});

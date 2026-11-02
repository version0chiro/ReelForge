import {
  clamp,
  computeAudioEnvelope,
  interpolateCrop,
  stabilizeCropSamples,
} from "./analysis.js";

const audioGraphs = new WeakMap();

function abortError() {
  return new DOMException("Operation cancelled", "AbortError");
}
function throwIfAborted(signal) {
  if (signal?.aborted) throw abortError();
}

function waitForEvent(target, eventName, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      cleanup();
      reject(new Error(`Timed out waiting for ${eventName}`));
    }, timeoutMs);

    const onEvent = () => {
      cleanup();
      resolve();
    };

    const onError = () => {
      cleanup();
      reject(target.error || new Error(`Failed while waiting for ${eventName}`));
    };

    function cleanup() {
      window.clearTimeout(timeout);
      target.removeEventListener(eventName, onEvent);
      target.removeEventListener("error", onError);
    }

    target.addEventListener(eventName, onEvent, { once: true });
    target.addEventListener("error", onError, { once: true });
  });
}

export async function loadVideoFile(video, file) {
  if (!(file instanceof File)) throw new TypeError("A video File is required");

  const objectUrl = URL.createObjectURL(file);
  const meta = await loadVideoUrl(video, objectUrl);
  return { objectUrl, ...meta };
}

export async function loadVideoUrl(video, objectUrl, signal) {
  if (!objectUrl) throw new TypeError("A video URL is required");
  throwIfAborted(signal);
  video.pause();

  if (video.dataset.reelforgeSource !== objectUrl) {
    video.dataset.reelforgeSource = objectUrl;
    video.src = objectUrl;
    video.load();
  }
  if (video.readyState < HTMLMediaElement.HAVE_METADATA) {
    await waitForEvent(video, "loadedmetadata", 20_000);
  }
  if (video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA) {
    await waitForEvent(video, "loadeddata", 20_000);
  }
  throwIfAborted(signal);

  return {
    duration: video.duration,
    width: video.videoWidth,
    height: video.videoHeight,
  };
}

export async function seekVideo(video, requestedTime, signal) {
  throwIfAborted(signal);
  const duration = Number.isFinite(video.duration) ? video.duration : 0;
  const target = clamp(Number(requestedTime) || 0, 0, Math.max(0, duration - 0.015));

  if (Math.abs(video.currentTime - target) < 0.012 && video.readyState >= 2) {
    return;
  }

  const seeked = waitForEvent(video, "seeked", 12_000);
  video.currentTime = target;
  await seeked;
  throwIfAborted(signal);
}

function samplingDimensions(video) {
  const aspect = video.videoWidth / Math.max(1, video.videoHeight);
  if (aspect >= 1) {
    return { width: 192, height: Math.max(80, Math.round(192 / aspect)) };
  }
  return { width: Math.max(80, Math.round(192 * aspect)), height: 192 };
}

function readFrameFeatures(imageData) {
  const pixels = imageData.data;
  const luma = new Uint8Array(pixels.length / 4);
  const histogram = new Float32Array(16);
  for (let source = 0, destination = 0; source < pixels.length; source += 4, destination += 1) {
    const value = (
      pixels[source] * 77
      + pixels[source + 1] * 150
      + pixels[source + 2] * 29
    ) >> 8;
    luma[destination] = value;
    histogram[Math.min(15, value >> 4)] += 1;
  }
  for (let index = 0; index < histogram.length; index += 1) {
    histogram[index] /= Math.max(1, luma.length);
  }
  return { luma, histogram };
}

function compareFrames(previous, current, width, height, previousCropX) {
  if (!previous || previous.luma.length !== current.luma.length) {
    return { motion: 0, scene: 0, cropX: previousCropX ?? 0.5 };
  }

  let differenceSum = 0;
  let changedPixels = 0;
  let motionWeight = 0;
  let weightedX = 0;
  const top = Math.floor(height * 0.06);
  const bottom = Math.ceil(height * 0.94);

  for (let index = 0; index < current.luma.length; index += 1) {
    const difference = Math.abs(current.luma[index] - previous.luma[index]);
    differenceSum += difference;
    if (difference > 44) changedPixels += 1;

    const y = Math.floor(index / width);
    if (y < top || y >= bottom) continue;
    const weight = Math.max(0, difference - 7);
    if (weight <= 0) continue;
    const x = index % width;
    motionWeight += weight;
    weightedX += (x / Math.max(1, width - 1)) * weight;
  }

  let histogramDifference = 0;
  for (let index = 0; index < current.histogram.length; index += 1) {
    histogramDifference += Math.abs(current.histogram[index] - previous.histogram[index]);
  }
  histogramDifference /= 2;

  const meanDifference = differenceSum / Math.max(1, current.luma.length);
  const changedRatio = changedPixels / Math.max(1, current.luma.length);
  const rawCropX = motionWeight > current.luma.length * 0.5
    ? weightedX / motionWeight
    : 0.5;
  const stableCropX = clamp(rawCropX, 0.08, 0.92);
  const cropX = clamp((previousCropX ?? 0.5) * 0.72 + stableCropX * 0.28, 0.08, 0.92);

  return {
    motion: clamp(meanDifference / 70, 0, 1.5),
    scene: clamp(histogramDifference * 2.25 + Math.max(0, changedRatio - 0.45) * 0.35, 0, 1.5),
    cropX,
  };
}

export async function analyzeVisualFeatures(video, options = {}) {
  const {
    quality = "balanced",
    onProgress = () => {},
    signal,
  } = options;
  const duration = video.duration;
  if (!Number.isFinite(duration) || duration <= 0) return [];

  const maxFrames = {
    fast: 500,
    balanced: 1_100,
    detailed: 2_200,
  }[quality] || 1_100;
  const interval = Math.max(0.16, duration / maxFrames);
  const frameCount = Math.max(2, Math.ceil(duration / interval));
  const { width, height } = samplingDimensions(video);
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d", {
    alpha: false,
    desynchronized: true,
    willReadFrequently: true,
  });
  const originalTime = video.currentTime;
  const wasPaused = video.paused;
  const results = [];
  let previousFrame = null;
  let cropX = 0.5;

  video.pause();

  try {
    for (let index = 0; index < frameCount; index += 1) {
      throwIfAborted(signal);
      const time = Math.min(duration - 0.02, index * interval);
      await seekVideo(video, time, signal);
      context.drawImage(video, 0, 0, width, height);
      const image = context.getImageData(0, 0, width, height);
      const frame = readFrameFeatures(image);
      const features = compareFrames(previousFrame, frame, width, height, cropX);
      cropX = features.cropX;
      results.push({ time, ...features });
      previousFrame = frame;
      onProgress((index + 1) / frameCount);
    }
  } finally {
    if (Number.isFinite(originalTime)) {
      try {
        await seekVideo(video, originalTime);
      } catch {
        // Keeping the last analyzed frame is safe if restoring the seek fails.
      }
    }
    if (!wasPaused) {
      video.play().catch(() => {});
    }
  }

  return stabilizeCropSamples(results);
}

export async function analyzeAudioFeatures(file, options = {}) {
  const {
    bucketSeconds = 0.1,
    maxBytes = 1_200_000_000,
    onProgress = () => {},
    signal,
  } = options;

  if (!window.AudioContext && !window.webkitAudioContext) {
    throw new Error("This browser does not expose Web Audio decoding");
  }
  if (file.size > maxBytes) {
    const error = new Error("Audio scan skipped because this file is over 1.2 GB");
    error.code = "FILE_TOO_LARGE_FOR_AUDIO_SCAN";
    throw error;
  }

  throwIfAborted(signal);
  onProgress(0.05);
  const encoded = await file.arrayBuffer();
  throwIfAborted(signal);
  onProgress(0.3);

  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  const context = new AudioContextClass();
  try {
    const decoded = await context.decodeAudioData(encoded);
    throwIfAborted(signal);
    onProgress(0.78);
    const envelope = computeAudioEnvelope(decoded, bucketSeconds);
    onProgress(1);
    return envelope;
  } finally {
    context.close().catch(() => {});
  }
}

function resolveCropCenter(samples, time, clip, cropStrength, cropBias) {
  const fixedCenters = {
    center: 0.5,
    left: 0.27,
    right: 0.73,
  };
  if (clip.cropMode in fixedCenters) return fixedCenters[clip.cropMode];

  const tracked = interpolateCrop(samples, time, clip.cropX ?? 0.5);
  const clipCenter = Number.isFinite(clip.cropX) ? clip.cropX : tracked;
  const dynamicCenter = tracked * 0.68 + clipCenter * 0.32;
  const strength = clamp(cropStrength, 0, 1);
  const biased = 0.5 + (dynamicCenter - 0.5) * strength + clamp(cropBias, -1, 1) * 0.18;
  return clamp(biased, 0.04, 0.96);
}

export function drawVideoFrame(context, video, canvas, options = {}) {
  if (!video.videoWidth || !video.videoHeight) return;

  const {
    cropCenter = 0.5,
    background = "#05070b",
    framingMode = "adaptive",
    cropMode = "auto",
    outputQuality = "enhanced",
  } = options;
  const sourceWidth = video.videoWidth;
  const sourceHeight = video.videoHeight;
  const sourceAspect = sourceWidth / sourceHeight;
  const targetAspect = canvas.width / canvas.height;
  const cropScale = canvas.height / sourceHeight;
  const useFit = cropMode === "fit"
    || framingMode === "fit"
    || (
      framingMode === "adaptive"
      && sourceAspect > targetAspect
      && (sourceHeight < 720 || cropScale > 2.45)
    );

  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = outputQuality === "enhanced" ? "high" : "medium";
  context.fillStyle = background;
  context.fillRect(0, 0, canvas.width, canvas.height);

  if (useFit) {
    const coverScale = Math.max(canvas.width / sourceWidth, canvas.height / sourceHeight) * 1.08;
    const coverWidth = sourceWidth * coverScale;
    const coverHeight = sourceHeight * coverScale;
    context.save();
    context.filter = `blur(${Math.max(14, Math.round(canvas.width * 0.032))}px) brightness(0.42) saturate(1.18)`;
    context.drawImage(
      video,
      (canvas.width - coverWidth) / 2,
      (canvas.height - coverHeight) / 2,
      coverWidth,
      coverHeight,
    );
    context.restore();

    context.fillStyle = "rgba(2, 4, 8, 0.14)";
    context.fillRect(0, 0, canvas.width, canvas.height);
    const containScale = Math.min(canvas.width / sourceWidth, canvas.height / sourceHeight);
    const containWidth = sourceWidth * containScale;
    const containHeight = sourceHeight * containScale;
    context.save();
    context.filter = outputQuality === "enhanced"
      ? "contrast(1.035) saturate(1.045)"
      : "none";
    context.drawImage(
      video,
      (canvas.width - containWidth) / 2,
      (canvas.height - containHeight) / 2,
      containWidth,
      containHeight,
    );
    context.restore();
    return;
  }

  let sourceX = 0;
  let sourceY = 0;
  let cropWidth = sourceWidth;
  let cropHeight = sourceHeight;

  if (sourceAspect > targetAspect) {
    cropWidth = sourceHeight * targetAspect;
    sourceX = clamp(
      cropCenter * sourceWidth - cropWidth / 2,
      0,
      sourceWidth - cropWidth,
    );
  } else if (sourceAspect < targetAspect) {
    cropHeight = sourceWidth / targetAspect;
    sourceY = (sourceHeight - cropHeight) / 2;
  }

  context.save();
  context.filter = outputQuality === "enhanced"
    ? "contrast(1.035) saturate(1.045)"
    : "none";
  context.drawImage(
    video,
    sourceX,
    sourceY,
    cropWidth,
    cropHeight,
    0,
    0,
    canvas.width,
    canvas.height,
  );
  context.restore();
}

export function renderCurrentFrame(video, canvas, samples, clip, options = {}) {
  const context = canvas.getContext("2d", { alpha: false, desynchronized: true });
  const cropCenter = resolveCropCenter(
    samples,
    video.currentTime,
    clip || { cropMode: "center", cropX: 0.5 },
    Number(options.cropStrength ?? 0.85),
    Number(options.cropBias ?? 0),
  );
  drawVideoFrame(context, video, canvas, {
    cropCenter,
    cropMode: clip?.cropMode,
    framingMode: options.framingMode,
    outputQuality: options.outputQuality,
  });
}

export async function playSequence(options) {
  const {
    video,
    canvas,
    clips,
    samples,
    getSamples = () => samples || [],
    prepareClip = async () => {},
    startIndex = 0,
    onlyOne = false,
    cropStrength = 0.85,
    cropBias = 0,
    framingMode = "adaptive",
    outputQuality = "enhanced",
    onProgress = () => {},
    onClip = () => {},
    signal,
  } = options;

  const selectedClips = onlyOne ? clips.slice(startIndex, startIndex + 1) : clips.slice(startIndex);
  const totalDuration = selectedClips.reduce((sum, clip) => sum + clip.end - clip.start, 0);
  let completedDuration = 0;

  for (let localIndex = 0; localIndex < selectedClips.length; localIndex += 1) {
    throwIfAborted(signal);
    const clip = selectedClips[localIndex];
    const actualIndex = startIndex + localIndex;
    await prepareClip(clip, signal);
    throwIfAborted(signal);
    const clipSamples = getSamples(clip) || [];
    onClip(actualIndex, clip);
    await seekVideo(video, clip.start, signal);
    renderCurrentFrame(video, canvas, clipSamples, clip, {
      cropStrength,
      cropBias,
      framingMode,
      outputQuality,
    });
    await video.play();

    await new Promise((resolve, reject) => {
      let animationFrame = 0;

      const finish = (error) => {
        cancelAnimationFrame(animationFrame);
        if (error) reject(error);
        else resolve();
      };

      const draw = () => {
        if (signal?.aborted) {
          finish(abortError());
          return;
        }

        renderCurrentFrame(video, canvas, clipSamples, clip, {
          cropStrength,
          cropBias,
          framingMode,
          outputQuality,
        });
        const clipProgress = clamp(video.currentTime - clip.start, 0, clip.end - clip.start);
        onProgress(
          totalDuration > 0 ? (completedDuration + clipProgress) / totalDuration : 1,
          actualIndex,
        );

        if (video.ended || video.currentTime >= clip.end - 0.018) {
          finish();
          return;
        }
        animationFrame = requestAnimationFrame(draw);
      };

      animationFrame = requestAnimationFrame(draw);
    });

    video.pause();
    completedDuration += clip.end - clip.start;
  }

  onProgress(1, startIndex + selectedClips.length - 1);
}

async function ensureAudioGraph(video) {
  if (audioGraphs.has(video)) {
    const existing = audioGraphs.get(video);
    await existing.context.resume();
    return existing;
  }

  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  if (!AudioContextClass) return null;

  const context = new AudioContextClass();
  const source = context.createMediaElementSource(video);
  const monitor = context.createGain();
  const recorderGain = context.createGain();
  const destination = context.createMediaStreamDestination();
  monitor.gain.value = 1;
  recorderGain.gain.value = 1;
  source.connect(monitor);
  monitor.connect(context.destination);
  source.connect(recorderGain);
  recorderGain.connect(destination);

  const graph = { context, source, monitor, recorderGain, destination };
  audioGraphs.set(video, graph);
  await context.resume();
  return graph;
}

const exportMimeCandidates = [
  'video/mp4;codecs="avc1.42E01E,mp4a.40.2"',
  "video/mp4",
  "video/webm;codecs=vp9,opus",
  "video/webm;codecs=vp8,opus",
  "video/webm",
];

const exportProfiles = {
  standard: {
    id: "standard",
    width: 720,
    height: 1280,
    videoBitsPerSecond: 8_000_000,
    label: "720×1280",
  },
  enhanced: {
    id: "enhanced",
    width: 1080,
    height: 1920,
    videoBitsPerSecond: 20_000_000,
    label: "1080×1920",
  },
};

export function getExportProfile(name = "enhanced") {
  return exportProfiles[name] || exportProfiles.enhanced;
}

export function assessOutputQuality(meta, options = {}) {
  if (!meta?.width || !meta?.height) return null;
  const profile = getExportProfile(options.outputQuality);
  const targetAspect = profile.width / profile.height;
  const sourceAspect = meta.width / meta.height;
  const cropScale = sourceAspect > targetAspect
    ? profile.height / meta.height
    : profile.width / meta.width;
  const fitScale = Math.min(profile.width / meta.width, profile.height / meta.height);
  const adaptiveUsesFit = sourceAspect > targetAspect
    && (meta.height < 720 || cropScale > 2.45);
  const resolvedMode = options.framingMode === "fit"
    || (options.framingMode !== "crop" && adaptiveUsesFit)
    ? "fit"
    : "crop";

  return {
    profile,
    cropScale,
    fitScale,
    resolvedMode,
    needsUpscale: (resolvedMode === "fit" ? fitScale : cropScale) > 1.02,
  };
}

export function getExportSupport() {
  if (!window.MediaRecorder || !HTMLCanvasElement.prototype.captureStream) {
    return null;
  }

  const mimeType = exportMimeCandidates.find((candidate) => MediaRecorder.isTypeSupported(candidate));
  if (!mimeType) return null;
  return {
    mimeType,
    extension: mimeType.startsWith("video/mp4") ? "mp4" : "webm",
  };
}

export async function exportMontage(options) {
  const {
    video,
    canvas,
    clips,
    samples,
    getSamples = () => samples || [],
    prepareClip = async () => {},
    restorePreview,
    cropStrength = 0.85,
    cropBias = 0,
    framingMode = "adaptive",
    outputQuality = "enhanced",
    onProgress = () => {},
    signal,
  } = options;
  const support = getExportSupport();
  if (!support) throw new Error("This browser cannot record the montage canvas");
  if (!clips.length) throw new Error("There are no clips to export");

  const originalWidth = canvas.width;
  const originalHeight = canvas.height;
  const profile = getExportProfile(outputQuality);
  const graph = await ensureAudioGraph(video);
  throwIfAborted(signal);

  canvas.width = profile.width;
  canvas.height = profile.height;
  const canvasStream = canvas.captureStream(30);
  const tracks = [...canvasStream.getVideoTracks()];
  if (graph) {
    graph.monitor.gain.value = 0;
    tracks.push(...graph.destination.stream.getAudioTracks());
  }
  const outputStream = new MediaStream(tracks);
  const chunks = [];
  let recorder;

  try {
    recorder = new MediaRecorder(outputStream, {
      mimeType: support.mimeType,
      videoBitsPerSecond: profile.videoBitsPerSecond,
      audioBitsPerSecond: 192_000,
    });
  } catch {
    recorder = new MediaRecorder(outputStream, { mimeType: support.mimeType });
  }

  const stopped = new Promise((resolve, reject) => {
    recorder.addEventListener("dataavailable", (event) => {
      if (event.data?.size) chunks.push(event.data);
    });
    recorder.addEventListener("stop", resolve, { once: true });
    recorder.addEventListener("error", () => reject(recorder.error || new Error("Export failed")), {
      once: true,
    });
  });

  try {
    recorder.start(1_000);
    await playSequence({
      video,
      canvas,
      clips,
      samples,
      getSamples,
      prepareClip,
      cropStrength,
      cropBias,
      framingMode,
      outputQuality,
      onProgress,
      signal,
    });
    recorder.stop();
    await stopped;
  } catch (error) {
    if (recorder.state !== "inactive") recorder.stop();
    await stopped.catch(() => {});
    throw error;
  } finally {
    video.pause();
    outputStream.getTracks().forEach((track) => track.stop());
    if (graph) graph.monitor.gain.value = 1;
    canvas.width = originalWidth;
    canvas.height = originalHeight;
    if (restorePreview) {
      await restorePreview().catch(() => {});
    } else {
      const firstClip = clips[0];
      renderCurrentFrame(video, canvas, getSamples(firstClip), firstClip, {
        cropStrength,
        cropBias,
        framingMode,
        outputQuality,
      });
    }
  }

  return {
    blob: new Blob(chunks, { type: support.mimeType }),
    profile,
    ...support,
  };
}

export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
  return url;
}

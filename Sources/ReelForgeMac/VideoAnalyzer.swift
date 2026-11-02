import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

struct VideoAnalysisResult {
    let samples: [FeatureSample]
    let audioWarning: String?
}

enum VideoAnalyzer {
    static func loadSource(url: URL) async throws -> VideoSource {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReelForgeError.noVideoTrack(url.lastPathComponent)
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        let displaySize = CGSize(
            width: abs(transformed.width),
            height: abs(transformed.height)
        )

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let thumbnailTime = CMTime(
            seconds: min(max(0.1, duration.seconds * 0.08), 2),
            preferredTimescale: 600
        )
        let thumbnail: NSImage?
        if let generated = try? await generator.image(at: thumbnailTime) {
            thumbnail = NSImage(cgImage: generated.image, size: displaySize)
        } else {
            thumbnail = nil
        }

        return VideoSource(
            id: UUID(),
            url: url,
            name: url.lastPathComponent,
            duration: duration.seconds,
            displaySize: displaySize,
            frameRate: frameRate,
            thumbnail: thumbnail
        )
    }

    static func analyze(
        source: VideoSource,
        quality: ScanQuality,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoAnalysisResult {
        let asset = AVURLAsset(url: source.url)
        let visual = try await scanVisual(
            asset: asset,
            duration: source.duration,
            interval: quality.visualInterval
        ) { value in
            progress(value * 0.8)
        }
        try Task.checkCancellation()

        let audio: [RawAudioSample]
        let audioWarning: String?
        do {
            audio = try await scanAudio(asset: asset) { value in
                progress(0.8 + value * 0.2)
            }
            audioWarning = audio.isEmpty ? "No readable audio track" : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            audio = []
            audioWarning = error.localizedDescription
            progress(1)
        }

        return VideoAnalysisResult(
            samples: merge(visual: visual, audio: audio, duration: source.duration),
            audioWarning: audioWarning
        )
    }

    private struct RawVisualSample {
        let time: Double
        let motion: Double
        let scene: Double
        let cropX: Double
    }

    private struct RawAudioSample {
        let time: Double
        let rms: Double
        let onset: Double
    }

    private struct PixelSignature {
        let luma: [UInt8]
        let histogram: [Double]
        let width: Int
        let height: Int
    }

    private static func scanVisual(
        asset: AVAsset,
        duration: Double,
        interval: Double,
        progress: (Double) -> Void
    ) async throws -> [RawVisualSample] {
        guard duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 192)
        let tolerance = CMTime(seconds: max(0.04, interval * 0.48), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let frameCount = max(2, Int(ceil(duration / interval)))
        var result: [RawVisualSample] = []
        var previous: PixelSignature?
        var previousCrop = 0.5
        result.reserveCapacity(frameCount)

        for index in 0..<frameCount {
            if Task.isCancelled { throw CancellationError() }
            let seconds = min(max(0, duration - 0.02), Double(index) * interval)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let generated = try? await generator.image(at: time),
                  let current = signature(for: generated.image) else {
                progress(Double(index + 1) / Double(frameCount))
                continue
            }

            let features = compare(previous: previous, current: current, previousCrop: previousCrop)
            result.append(
                RawVisualSample(
                    time: seconds,
                    motion: features.motion,
                    scene: features.scene,
                    cropX: features.cropX
                )
            )
            previous = current
            previousCrop = features.cropX
            progress(Double(index + 1) / Double(frameCount))
        }
        return stabilizeCrop(result)
    }

    private static func signature(for image: CGImage) -> PixelSignature? {
        let aspect = Double(image.width) / Double(max(1, image.height))
        let width: Int
        let height: Int
        if aspect >= 1 {
            width = 160
            height = max(72, Int((160 / aspect).rounded()))
        } else {
            height = 160
            width = max(72, Int((160 * aspect).rounded()))
        }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { return nil }

        var luma = [UInt8](repeating: 0, count: width * height)
        var histogram = [Double](repeating: 0, count: 16)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let value = (
                Int(pixels[offset]) * 77
                    + Int(pixels[offset + 1]) * 150
                    + Int(pixels[offset + 2]) * 29
            ) >> 8
            luma[pixel] = UInt8(clamping: value)
            histogram[min(15, value >> 4)] += 1
        }
        let pixelCount = Double(max(1, luma.count))
        histogram = histogram.map { $0 / pixelCount }
        return PixelSignature(luma: luma, histogram: histogram, width: width, height: height)
    }

    private static func compare(
        previous: PixelSignature?,
        current: PixelSignature,
        previousCrop: Double
    ) -> (motion: Double, scene: Double, cropX: Double) {
        guard let previous, previous.luma.count == current.luma.count else {
            return (0, 0, previousCrop)
        }

        var differenceSum = 0.0
        var changedPixels = 0
        var motionWeight = 0.0
        var weightedX = 0.0
        let top = Int(Double(current.height) * 0.06)
        let bottom = Int(ceil(Double(current.height) * 0.94))

        for index in current.luma.indices {
            let difference = abs(Int(current.luma[index]) - Int(previous.luma[index]))
            differenceSum += Double(difference)
            if difference > 44 { changedPixels += 1 }
            let y = index / current.width
            guard y >= top, y < bottom else { continue }
            let weight = Double(max(0, difference - 7))
            guard weight > 0 else { continue }
            let x = index % current.width
            motionWeight += weight
            weightedX += Double(x) / Double(max(1, current.width - 1)) * weight
        }

        let histogramDifference = zip(current.histogram, previous.histogram)
            .map { abs($0 - $1) }
            .reduce(0, +) / 2
        let pixelCount = Double(max(1, current.luma.count))
        let meanDifference = differenceSum / pixelCount
        let changedRatio = Double(changedPixels) / pixelCount
        let rawCrop = motionWeight > pixelCount * 0.5 ? weightedX / motionWeight : 0.5
        let stable = min(0.92, max(0.08, rawCrop))
        let cropX = min(0.92, max(0.08, previousCrop * 0.72 + stable * 0.28))
        return (
            min(1.5, max(0, meanDifference / 70)),
            min(1.5, max(0, histogramDifference * 2.25 + max(0, changedRatio - 0.45) * 0.35)),
            cropX
        )
    }

    private static func stabilizeCrop(_ samples: [RawVisualSample]) -> [RawVisualSample] {
        guard samples.count > 1 else { return samples }
        let radius = 3
        let maxStep = 0.055
        var previous = min(0.92, max(0.08, samples[0].cropX))
        return samples.indices.map { index in
            var totalWeight = 0.0
            var weightedX = 0.0
            for neighbor in max(0, index - radius)...min(samples.count - 1, index + radius) {
                let candidate = samples[neighbor]
                let distanceWeight = 1 - Double(abs(neighbor - index)) / Double(radius + 1)
                let motionWeight = 0.35 + min(1, max(0, candidate.motion))
                let weight = distanceWeight * motionWeight
                weightedX += min(0.92, max(0.08, candidate.cropX)) * weight
                totalWeight += weight
            }
            var desired = totalWeight > 0 ? weightedX / totalWeight : 0.5
            if abs(desired - 0.5) <= 0.055 { desired = 0.5 }
            let allowedStep = samples[index].scene >= 0.82 ? 0.18 : maxStep
            let delta = min(allowedStep, max(-allowedStep, desired - previous))
            previous = min(0.92, max(0.08, previous + delta))
            return RawVisualSample(
                time: samples[index].time,
                motion: samples[index].motion,
                scene: samples[index].scene,
                cropX: previous
            )
        }
    }

    private static func scanAudio(
        asset: AVAsset,
        progress: (Double) -> Void
    ) async throws -> [RawAudioSample] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            progress(1)
            return []
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: [track],
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ReelForgeError.analysisFailed("Audio decoder could not be attached")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ReelForgeError.analysisFailed("Audio decoding did not start")
        }

        var result: [RawAudioSample] = []
        var previousRMS = 0.0
        var previousPeak = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var lengthAtOffset = 0
            var totalLength = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &pointer
            )
            guard status == kCMBlockBufferNoErr, let pointer, totalLength >= MemoryLayout<Float>.size else {
                continue
            }
            let count = totalLength / MemoryLayout<Float>.size
            let floats = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            let stride = max(1, count / 4_096)
            var squareSum = 0.0
            var peak = 0.0
            var sampleCount = 0
            var index = 0
            while index < count {
                let magnitude = abs(Double(floats[index]))
                if magnitude.isFinite {
                    squareSum += magnitude * magnitude
                    peak = max(peak, magnitude)
                    sampleCount += 1
                }
                index += stride
            }
            guard sampleCount > 0 else { continue }
            let rms = sqrt(squareSum / Double(sampleCount))
            let onset = max(0, rms - previousRMS * 0.9) + max(0, peak - previousPeak) * 0.3
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            result.append(RawAudioSample(time: time, rms: rms, onset: onset))
            previousRMS = rms
            previousPeak = peak
            progress(min(1, max(0, time / max(0.001, duration))))
        }
        progress(1)
        if reader.status == .failed {
            throw reader.error ?? ReelForgeError.analysisFailed("Audio decoding failed")
        }
        return result
    }

    private static func merge(
        visual: [RawVisualSample],
        audio: [RawAudioSample],
        duration: Double
    ) -> [FeatureSample] {
        guard duration > 0 else { return [] }
        let interval = 0.1
        let count = max(1, Int(ceil(duration / interval)))
        return (0..<count).map { index in
            let time = min(duration, Double(index) * interval)
            return FeatureSample(
                time: time,
                audioRMS: interpolate(audio, time: time, value: \.rms),
                audioOnset: interpolate(audio, time: time, value: \.onset),
                motion: interpolate(visual, time: time, value: \.motion),
                scene: interpolate(visual, time: time, value: \.scene),
                cropX: visual.isEmpty ? 0.5 : interpolate(visual, time: time, value: \.cropX)
            )
        }
    }

    private static func interpolate<Value>(
        _ samples: [Value],
        time: Double,
        sampleTime: (Value) -> Double,
        value: (Value) -> Double
    ) -> Double {
        guard let first = samples.first else { return 0 }
        guard samples.count > 1 else { return value(first) }
        if time <= sampleTime(first) { return value(first) }
        guard let last = samples.last else { return 0 }
        if time >= sampleTime(last) { return value(last) }
        var low = 0
        var high = samples.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if sampleTime(samples[middle]) <= time {
                low = middle
            } else {
                high = middle
            }
        }
        let from = samples[low]
        let to = samples[high]
        let span = max(0.000_001, sampleTime(to) - sampleTime(from))
        let position = min(1, max(0, (time - sampleTime(from)) / span))
        return value(from) + (value(to) - value(from)) * position
    }

    private static func interpolate(
        _ samples: [RawVisualSample],
        time: Double,
        value: KeyPath<RawVisualSample, Double>
    ) -> Double {
        interpolate(samples, time: time, sampleTime: \.time, value: { $0[keyPath: value] })
    }

    private static func interpolate(
        _ samples: [RawAudioSample],
        time: Double,
        value: KeyPath<RawAudioSample, Double>
    ) -> Double {
        interpolate(samples, time: time, sampleTime: \.time, value: { $0[keyPath: value] })
    }
}

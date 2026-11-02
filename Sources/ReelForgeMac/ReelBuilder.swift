@preconcurrency import AVFoundation
import Foundation

enum ReelBuilder {
    static func build(
        sources: [VideoSource],
        highlights: [Highlight],
        settings: RenderSettings
    ) async throws -> BuiltReel {
        guard !highlights.isEmpty else { throw ReelForgeError.noHighlights }
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ReelForgeError.cannotCreateCompositionTrack
        }
        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let sourceMap = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var cursor = CMTime.zero
        var instructions: [ReelVideoInstruction] = []

        for highlight in highlights {
            guard let source = sourceMap[highlight.sourceID] else { continue }
            let asset = AVURLAsset(url: source.url)
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ReelForgeError.noVideoTrack(source.name)
            }
            let assetDuration = try await asset.load(.duration)
            let safeStart = min(max(0, highlight.start), max(0, assetDuration.seconds - 0.05))
            let safeDuration = min(
                max(0.05, highlight.duration),
                max(0.05, assetDuration.seconds - safeStart)
            )
            let clipDuration = CMTime(seconds: safeDuration, preferredTimescale: 600)
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: safeStart, preferredTimescale: 600),
                duration: clipDuration
            )
            try compositionVideoTrack.insertTimeRange(sourceRange, of: videoTrack, at: cursor)

            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack {
                try? compositionAudioTrack.insertTimeRange(sourceRange, of: audioTrack, at: cursor)
            }

            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let naturalSize = try await videoTrack.load(.naturalSize)
            let displayRect = CGRect(origin: .zero, size: naturalSize)
                .applying(preferredTransform)
                .standardized
            let destinationRange = CMTimeRange(start: cursor, duration: clipDuration)
            let cropCenter = resolvedCropCenter(
                highlight: highlight,
                strength: settings.cropStrength,
                bias: settings.cropBias
            )
            instructions.append(
                ReelVideoInstruction(
                    timeRange: destinationRange,
                    sourceTrackID: compositionVideoTrack.trackID,
                    preferredTransform: preferredTransform,
                    displaySize: CGSize(
                        width: abs(displayRect.width),
                        height: abs(displayRect.height)
                    ),
                    cropCenter: cropCenter,
                    framing: highlight.framingOverride ?? settings.framing,
                    quality: settings.quality
                )
            )
            cursor = cursor + clipDuration
        }

        guard cursor > .zero else { throw ReelForgeError.noHighlights }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ReelVideoCompositor.self
        videoComposition.renderSize = settings.quality.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        videoComposition.renderScale = 1
        return BuiltReel(
            composition: composition,
            videoComposition: videoComposition,
            duration: cursor,
            quality: settings.quality
        )
    }

    private static func resolvedCropCenter(
        highlight: Highlight,
        strength: Double,
        bias: Double
    ) -> CGFloat {
        let tracked = 0.5 + (highlight.cropX - 0.5) * min(1, max(0, strength))
        return CGFloat(min(0.96, max(0.04, tracked + min(1, max(-1, bias)) * 0.18)))
    }
}

enum ReelExporter {
    static func export(_ reel: BuiltReel, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: reel.composition)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoTracks = try await reel.composition.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        videoOutput.videoComposition = reel.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ReelForgeError.exportFailed("The custom video output could not be attached")
        }
        reader.add(videoOutput)

        let renderSize = reel.quality.renderSize
        let videoBitrate = reel.quality == .enhanced ? 20_000_000 : 8_000_000
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(renderSize.width),
                AVVideoHeightKey: Int(renderSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitrate,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ReelForgeError.exportFailed("The H.264 encoder could not be attached")
        }
        writer.add(videoInput)

        let audioTracks = try await reel.composition.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ]
            )
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioOutput = output
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? ReelForgeError.exportFailed("The MP4 writer did not start")
        }
        guard reader.startReading() else {
            throw reader.error ?? ReelForgeError.exportFailed("The montage reader did not start")
        }
        writer.startSession(atSourceTime: .zero)

        let state = ExportState()
        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "com.reelforge.export.video", qos: .userInitiated)
        group.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    if reader.status == .failed {
                        state.record(reader.error ?? ReelForgeError.exportFailed("Video decoding failed"))
                    }
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                guard videoInput.append(sample) else {
                    state.record(writer.error ?? ReelForgeError.exportFailed("A video frame could not be encoded"))
                    reader.cancelReading()
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        if let audioOutput, let audioInput {
            let audioQueue = DispatchQueue(label: "com.reelforge.export.audio", qos: .userInitiated)
            group.enter()
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        if reader.status == .failed {
                            state.record(reader.error ?? ReelForgeError.exportFailed("Audio decoding failed"))
                        }
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard audioInput.append(sample) else {
                        state.record(writer.error ?? ReelForgeError.exportFailed("Audio could not be encoded"))
                        reader.cancelReading()
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.notify(queue: videoQueue) {
                if let error = state.error {
                    writer.cancelWriting()
                    continuation.resume(throwing: error)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: writer.error
                                ?? reader.error
                                ?? ReelForgeError.exportFailed("The MP4 writer did not finish")
                        )
                    }
                }
            }
        }
    }

    private final class ExportState: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func record(_ error: Error) {
            lock.lock()
            if storedError == nil { storedError = error }
            lock.unlock()
        }
    }
}

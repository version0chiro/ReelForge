import AppKit
import AVFoundation
import Foundation

enum ScanQuality: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .detailed: "Detailed"
        }
    }

    var visualInterval: Double {
        switch self {
        case .fast: 0.38
        case .balanced: 0.22
        case .detailed: 0.12
        }
    }
}

enum ReelOrder: String, CaseIterable, Identifiable {
    case hookFirst
    case sourceOrder

    var id: String { rawValue }
    var label: String { self == .hookFirst ? "Hook first" : "Source order" }
}

enum FramingMode: String, CaseIterable, Identifiable {
    case adaptive
    case crop
    case fit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive: "Adaptive quality"
        case .crop: "Fill 9:16"
        case .fit: "Full frame + blur"
        }
    }
}

enum OutputQuality: String, CaseIterable, Identifiable {
    case standard
    case enhanced

    var id: String { rawValue }
    var renderSize: CGSize {
        switch self {
        case .standard: CGSize(width: 720, height: 1280)
        case .enhanced: CGSize(width: 1080, height: 1920)
        }
    }

    var label: String {
        switch self {
        case .standard: "Standard · 720p"
        case .enhanced: "Enhanced · 1080p"
        }
    }
}

struct DetectionSettings: Equatable {
    var targetDuration: Double = 15
    var sequenceDuration: Double = 3.5
    var audioWeight: Double = 0.55
    var sensitivity: Double = 0.58
    var order: ReelOrder = .hookFirst
    var scanQuality: ScanQuality = .balanced
}

struct RenderSettings: Equatable {
    var framing: FramingMode = .adaptive
    var quality: OutputQuality = .enhanced
    var cropStrength: Double = 0.85
    var cropBias: Double = 0
}

struct FeatureSample: Equatable {
    var time: Double
    var audioRMS: Double
    var audioOnset: Double
    var motion: Double
    var scene: Double
    var cropX: Double
}

struct ScoredSample: Equatable {
    var sample: FeatureSample
    var audioScore: Double
    var motionScore: Double
    var sceneScore: Double
    var visualScore: Double
    var score: Double
}

struct VideoSource: Identifiable {
    let id: UUID
    let url: URL
    let name: String
    let duration: Double
    let displaySize: CGSize
    let frameRate: Float
    var thumbnail: NSImage?
    var samples: [FeatureSample] = []
    var scoredSamples: [ScoredSample] = []
    var scannedQuality: ScanQuality?
    var audioWarning: String?

    var resolutionLabel: String {
        "\(Int(displaySize.width.rounded()))×\(Int(displaySize.height.rounded()))"
    }
}

struct Highlight: Identifiable, Equatable {
    let id: UUID
    var sourceID: UUID
    var sourceIndex: Int
    var sourceName: String
    var start: Double
    var end: Double
    var peak: Double
    var score: Double
    var peakScore: Double
    var sequenceStrength: Double
    var cropX: Double
    var framingOverride: FramingMode?
    var reasons: [String]

    var duration: Double { max(0, end - start) }
}

struct BuiltReel {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let duration: CMTime
    let quality: OutputQuality
}

enum ReelForgeError: LocalizedError {
    case noVideoTrack(String)
    case noHighlights
    case cannotCreateCompositionTrack
    case cannotCreateExporter
    case exportFailed(String)
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case let .noVideoTrack(name):
            "No readable video track was found in \(name)."
        case .noHighlights:
            "Analyze the imported footage before building a Reel."
        case .cannotCreateCompositionTrack:
            "AVFoundation could not create the montage tracks."
        case .cannotCreateExporter:
            "AVFoundation could not create an export session."
        case let .exportFailed(message):
            "Export failed: \(message)"
        case let .analysisFailed(message):
            "Analysis failed: \(message)"
        }
    }
}

extension Double {
    var reelTime: String {
        let safe = max(0, self)
        let minutes = Int(safe) / 60
        let seconds = Int(safe) % 60
        let tenths = Int((safe - floor(safe)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

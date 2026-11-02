import AVFoundation
import Foundation

@main
struct ReelForgeSmoke {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            fputs("Usage: reelforge-smoke OUTPUT.mp4 VIDEO [VIDEO ...]\n", stderr)
            exit(64)
        }

        let output = URL(fileURLWithPath: arguments[0])
        let inputURLs = arguments.dropFirst().map(URL.init(fileURLWithPath:))

        do {
            var sources: [VideoSource] = []
            for url in inputURLs {
                let source = try await VideoAnalyzer.loadSource(url: url)
                print("SOURCE \(source.name) \(source.duration.reelTime) \(source.resolutionLabel)")
                sources.append(source)
            }

            for index in sources.indices {
                let source = sources[index]
                let result = try await VideoAnalyzer.analyze(source: source, quality: .fast) { progress in
                    if Int(progress * 100).isMultiple(of: 25) {
                        fputs("SCAN \(index + 1)/\(sources.count) \(Int(progress * 100))%\n", stderr)
                    }
                }
                sources[index].samples = result.samples
                sources[index].scannedQuality = .fast
                sources[index].audioWarning = result.audioWarning
                print("SIGNALS \(source.name) \(result.samples.count)")
                print(
                    "MAX \(source.name) "
                        + "audio=\(String(format: "%.5f", result.samples.map(\.audioRMS).max() ?? 0)) "
                        + "onset=\(String(format: "%.5f", result.samples.map(\.audioOnset).max() ?? 0)) "
                        + "motion=\(String(format: "%.5f", result.samples.map(\.motion).max() ?? 0)) "
                        + "scene=\(String(format: "%.5f", result.samples.map(\.scene).max() ?? 0)) "
                        + "warning=\(result.audioWarning ?? "none")"
                )
            }

            let detected = HighlightDetector.detect(
                sources: sources,
                settings: DetectionSettings(
                    targetDuration: 7,
                    sequenceDuration: 2.3,
                    audioWeight: 0.55,
                    sensitivity: 0.58,
                    order: .hookFirst,
                    scanQuality: .fast
                )
            )
            guard !detected.highlights.isEmpty else {
                throw ReelForgeError.noHighlights
            }
            for (index, highlight) in detected.highlights.enumerated() {
                print(
                    "CUT \(index + 1) SOURCE \(highlight.sourceIndex + 1) "
                        + "\(highlight.start.reelTime)-\(highlight.end.reelTime) "
                        + "EPIC \(Int(highlight.score * 100)) "
                        + highlight.reasons.joined(separator: ",")
                )
            }

            let built = try await ReelBuilder.build(
                sources: sources,
                highlights: detected.highlights,
                settings: RenderSettings(
                    framing: .adaptive,
                    quality: .enhanced,
                    cropStrength: 0.85,
                    cropBias: 0
                )
            )
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await ReelExporter.export(built, to: output)
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            let bytes = attributes[.size] as? NSNumber
            print("EXPORTED \(output.path) \(bytes?.intValue ?? 0) bytes")
        } catch {
            fputs("ERROR \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

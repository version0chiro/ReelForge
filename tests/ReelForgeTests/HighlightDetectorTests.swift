import Foundation
import XCTest
@testable import ReelForgeMac

final class HighlightDetectorTests: XCTestCase {
    func testSelectsFromEverySourceWhenThereIsRoom() {
        let sources = (0..<3).map { index in
            makeSource(
                name: "source-\(index)",
                peakTime: Double(5 + index * 7),
                peakStrength: 0.7 + Double(index) * 0.1
            )
        }
        let result = HighlightDetector.detect(
            sources: sources,
            settings: DetectionSettings(targetDuration: 15, sequenceDuration: 3.5)
        )

        XCTAssertGreaterThanOrEqual(Set(result.highlights.map(\.sourceID)).count, 3)
        XCTAssertLessThanOrEqual(result.highlights.map(\.duration).reduce(0, +), 15.001)
    }

    func testHookFirstUsesStrongestEpicSequence() {
        let weak = makeSource(name: "weak", peakTime: 6, peakStrength: 0.55)
        let strong = makeSource(name: "strong", peakTime: 18, peakStrength: 1)
        let result = HighlightDetector.detect(
            sources: [weak, strong],
            settings: DetectionSettings(targetDuration: 7, sequenceDuration: 3.5, order: .hookFirst)
        )

        XCTAssertEqual(result.highlights.first?.sourceID, strong.id)
        XCTAssertGreaterThanOrEqual(result.highlights[0].score, result.highlights[1].score)
    }

    func testVisualSignalStillWorksWithoutAudio() {
        var source = makeSource(name: "visual", peakTime: 12, peakStrength: 1)
        source.samples = source.samples.map {
            FeatureSample(
                time: $0.time,
                audioRMS: 0,
                audioOnset: 0,
                motion: $0.motion,
                scene: $0.scene,
                cropX: $0.cropX
            )
        }
        let result = HighlightDetector.detect(
            sources: [source],
            settings: DetectionSettings(targetDuration: 4, sequenceDuration: 4, audioWeight: 1)
        )
        XCTAssertEqual(result.highlights.count, 1)
        XCTAssertTrue(result.highlights[0].start <= 12)
        XCTAssertTrue(result.highlights[0].end >= 12)
    }

    private func makeSource(name: String, peakTime: Double, peakStrength: Double) -> VideoSource {
        let id = UUID()
        let samples = stride(from: 0.0, through: 30.0, by: 0.25).map { time in
            let distance = abs(time - peakTime)
            let envelope = max(0, 1 - distance / 1.5) * peakStrength
            return FeatureSample(
                time: time,
                audioRMS: 0.03 + envelope,
                audioOnset: distance < 0.3 ? envelope : 0,
                motion: 0.02 + envelope,
                scene: distance < 0.3 ? envelope * 0.8 : 0.01,
                cropX: peakTime > 10 ? 0.72 : 0.4
            )
        }
        return VideoSource(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(name).mp4"),
            name: name,
            duration: 30,
            displaySize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            samples: samples
        )
    }
}

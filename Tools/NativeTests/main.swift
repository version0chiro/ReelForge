import Foundation
import SwiftUI

private final class BindingBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@main
struct NativeTests {
    static func main() {
        testCrossSourceDiversity()
        testHookFirst()
        testTargetDuration()
        testStaleHighlightBinding()
        testPublicDriveFolderURL()
        testPublicDriveFolderParsing()
        testPublicDriveConfirmationForm()
        print("Native tests passed (7/7)")
    }

    private static func testCrossSourceDiversity() {
        let sources = [
            source(name: "one", peak: 4, strength: 0.7),
            source(name: "two", peak: 12, strength: 0.8),
            source(name: "three", peak: 20, strength: 1),
        ]
        let result = HighlightDetector.detect(
            sources: sources,
            settings: DetectionSettings(targetDuration: 7, sequenceDuration: 2.3)
        )
        precondition(
            Set(result.highlights.map(\.sourceID)).count == 3,
            "Expected all three sources to be represented"
        )
    }

    private static func testHookFirst() {
        let weak = source(name: "weak", peak: 6, strength: 0.5)
        let strong = source(name: "strong", peak: 18, strength: 1)
        let result = HighlightDetector.detect(
            sources: [weak, strong],
            settings: DetectionSettings(targetDuration: 7, sequenceDuration: 3.5, order: .hookFirst)
        )
        precondition(result.highlights.first?.sourceID == strong.id, "Strongest sequence must open")
    }

    private static func testTargetDuration() {
        let result = HighlightDetector.detect(
            sources: [source(name: "duration", peak: 15, strength: 1)],
            settings: DetectionSettings(targetDuration: 7, sequenceDuration: 3)
        )
        let total = result.highlights.map(\.duration).reduce(0, +)
        precondition(total <= 7.001, "Montage exceeded its target duration")
    }

    private static func testStaleHighlightBinding() {
        let original = Highlight(
            id: UUID(),
            sourceID: UUID(),
            sourceIndex: 0,
            sourceName: "binding",
            start: 2,
            end: 5,
            peak: 3,
            score: 0.8,
            peakScore: 0.9,
            sequenceStrength: 0.85,
            cropX: 0.5,
            framingOverride: nil,
            reasons: ["motion"]
        )
        let box = BindingBox([original])
        let collection = Binding<[Highlight]>(
            get: { box.value },
            set: { box.value = $0 }
        )
        let row = safeElementBinding(
            fallback: original,
            elements: collection,
            id: \.id
        )

        box.value.removeAll()
        precondition(row.wrappedValue == original, "A removed row must use its safe fallback")

        var edited = original
        edited.start = 1
        row.wrappedValue = edited
        precondition(box.value.isEmpty, "A stale row must not recreate a removed highlight")

        box.value = [original]
        row.wrappedValue = edited
        precondition(box.value.first?.start == 1, "A live row must still update normally")
    }

    private static func testPublicDriveFolderURL() {
        let folderID = "1uUbx_lRLLE9O4WnI8TS77dUOJw_DjljV"
        let parsed = try? PublicGoogleDriveClient.folderID(
            from: "https://drive.google.com/drive/folders/\(folderID)?usp=sharing"
        )
        precondition(parsed == folderID, "A shared Drive folder URL must yield its folder ID")
        precondition(
            (try? PublicGoogleDriveClient.folderID(
                from: "https://example.com/drive/folders/\(folderID)"
            )) == nil,
            "Non-Google URLs must be rejected"
        )
    }

    private static func testPublicDriveFolderParsing() {
        let folderID = "1uUbx_lRLLE9O4WnI8TS77dUOJw_DjljV"
        let videoID = "1abcdefghijABCDEFGHIJ012345"
        let childID = "1zyxwvutsrqZYXWVUTSRQ98765"
        let html = """
        <html>
          <head><title>Gameplay &amp; Finals</title></head>
          <body>
            <a href="https://drive.google.com/file/d/\(videoID)/view">
              <img alt="">match &amp; clutch.mp4
            </a>
            <a href="https://drive.google.com/drive/folders/\(childID)">
              Extra rounds
            </a>
          </body>
        </html>
        """
        let parsed = try? PublicGoogleDriveClient.parseFolderHTML(
            html,
            folderID: folderID
        )
        precondition(
            parsed?.name == "Gameplay & Finals",
            "The public folder title must be decoded"
        )
        precondition(
            parsed?.entries.contains(where: {
                $0.id == videoID && $0.name == "match & clutch.mp4" && !$0.isFolder
            }) == true,
            "Public video links must be discovered"
        )
        precondition(
            parsed?.entries.contains(where: {
                $0.id == childID && $0.name == "Extra rounds" && $0.isFolder
            }) == true,
            "Nested public folders must be discovered"
        )
    }

    private static func testPublicDriveConfirmationForm() {
        let html = """
        <form id="download-form" action="https://drive.usercontent.google.com/download">
          <input type="hidden" name="id" value="video123456789">
          <input type="hidden" name="confirm" value="t">
        </form>
        """
        let url = PublicGoogleDriveClient.confirmationURL(
            from: html,
            baseURL: URL(string: "https://drive.google.com")!
        )
        let components = url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        precondition(
            components?.queryItems?.contains(URLQueryItem(name: "id", value: "video123456789")) == true,
            "Large-file confirmation must preserve the file ID"
        )
        precondition(
            components?.queryItems?.contains(URLQueryItem(name: "confirm", value: "t")) == true,
            "Large-file confirmation must preserve its token"
        )
    }

    private static func source(name: String, peak: Double, strength: Double) -> VideoSource {
        let samples = stride(from: 0.0, through: 30.0, by: 0.1).map { time in
            let envelope = max(0, 1 - abs(time - peak) / 1.8) * strength
            return FeatureSample(
                time: time,
                audioRMS: 0.02 + envelope,
                audioOnset: abs(time - peak) < 0.2 ? envelope : 0,
                motion: 0.02 + envelope,
                scene: abs(time - peak) < 0.3 ? envelope : 0,
                cropX: peak > 10 ? 0.7 : 0.4
            )
        }
        return VideoSource(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/\(name).mp4"),
            name: name,
            duration: 30,
            displaySize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            samples: samples
        )
    }
}

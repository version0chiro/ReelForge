import AppKit
@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [VideoSource] = []
    @Published var highlights: [Highlight] = []
    @Published var detection = DetectionSettings()
    @Published var render = RenderSettings()
    @Published var status = "Import several gameplay videos to begin."
    @Published var progress = 0.0
    @Published var isBusy = false
    @Published var isPlaying = false
    @Published var lastExportURL: URL?
    @Published var publicDriveFolderURL = ""
    @Published private(set) var publicDriveFolderName: String?

    let player = AVPlayer()
    private var preview: BuiltReel?
    private var operationTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var preferredExportDirectory: URL?
    private var publicDriveTemporaryDirectory: URL?

    var totalFootageDuration: Double {
        sources.map(\.duration).reduce(0, +)
    }

    var reelDuration: Double {
        highlights.map(\.duration).reduce(0, +)
    }

    var selectedSourceCount: Int {
        Set(highlights.map(\.sourceID)).count
    }

    var isPublicDriveFlow: Bool {
        publicDriveFolderName != nil
    }

    func chooseVideos(replacing: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = replacing ? "Replace gameplay sources" : "Add gameplay sources"
        panel.prompt = replacing ? "Replace" : "Add videos"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importVideos(panel.urls, replacing: replacing)
    }

    func importPublicDriveFolder() {
        let urlText = publicDriveFolderURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty, !isBusy else {
            if urlText.isEmpty {
                status = "Paste an “Anyone with the link” Google Drive folder URL first."
            }
            return
        }

        do {
            _ = try PublicGoogleDriveClient.folderID(from: urlText)
        } catch {
            status = error.localizedDescription
            return
        }

        operationTask?.cancel()
        operationTask = Task {
            isBusy = true
            progress = 0
            status = "Reading the public Google Drive folder…"
            var downloadDirectory: URL?

            do {
                let client = PublicGoogleDriveClient()
                let folder = try await client.discoverFolder(from: urlText) { [weak self] amount, name in
                    Task { @MainActor in
                        self?.progress = min(0.15, amount * 0.15)
                        self?.status = "Reading public Drive folder: \(name)"
                    }
                }
                try Task.checkCancellation()

                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ReelForge-PublicDrive-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                downloadDirectory = directory
                status = "Downloading \(folder.videos.count) public Drive video(s)…"

                let downloaded = try await client.downloadVideos(
                    folder.videos,
                    to: directory
                ) { [weak self] amount, name in
                    Task { @MainActor in
                        self?.progress = 0.15 + amount * 0.65
                        self?.status = "Downloading from Drive: \(name)"
                    }
                }
                try Task.checkCancellation()

                isBusy = false
                progress = 0
                operationTask = nil
                importVideos(
                    downloaded,
                    replacing: true,
                    autoScan: true,
                    publicDriveFolderName: folder.name,
                    temporaryDirectory: directory
                )
            } catch is CancellationError {
                if let downloadDirectory {
                    removeOwnedTemporaryDirectory(downloadDirectory)
                }
                status = "Public Drive import cancelled."
                isBusy = false
                progress = 0
            } catch let error as URLError where error.code == .cancelled {
                if let downloadDirectory {
                    removeOwnedTemporaryDirectory(downloadDirectory)
                }
                status = "Public Drive import cancelled."
                isBusy = false
                progress = 0
            } catch {
                if let downloadDirectory {
                    removeOwnedTemporaryDirectory(downloadDirectory)
                }
                status = error.localizedDescription
                isBusy = false
                progress = 0
            }
        }
    }

    func importVideos(
        _ urls: [URL],
        replacing: Bool = false,
        autoScan: Bool = false,
        publicDriveFolderName: String? = nil,
        temporaryDirectory: URL? = nil
    ) {
        guard !urls.isEmpty, !isBusy else { return }
        operationTask?.cancel()
        operationTask = Task {
            isBusy = true
            progress = 0
            status = publicDriveFolderName == nil
                ? "Reading video metadata…"
                : "Reading downloaded Drive video metadata…"
            if replacing {
                previewTask?.cancel()
                player.pause()
                player.replaceCurrentItem(with: nil)
                sources = []
                highlights = []
                preview = nil
                replacePublicDriveTemporaryDirectory(with: temporaryDirectory)
                self.publicDriveFolderName = publicDriveFolderName
                preferredExportDirectory = publicDriveFolderName == nil
                    ? nil
                    : FileManager.default.urls(
                        for: .moviesDirectory,
                        in: .userDomainMask
                    ).first
            }

            var failures: [String] = []
            for (offset, url) in urls.enumerated() {
                do {
                    let source = try await VideoAnalyzer.loadSource(url: url)
                    if !sources.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                        sources.append(source)
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                progress = Double(offset + 1) / Double(urls.count)
            }

            isBusy = false
            progress = 0
            if sources.isEmpty {
                status = failures.first ?? "No readable videos were selected."
                replacePublicDriveTemporaryDirectory(with: nil)
                self.publicDriveFolderName = nil
            } else if failures.isEmpty {
                status = "\(sources.count) source videos ready. Scan for epic sequences."
            } else {
                status = "Loaded \(sources.count) videos; \(failures.count) could not be read."
            }

            if autoScan, !sources.isEmpty {
                status = publicDriveFolderName == nil
                    ? "Videos ready. Finding epic sequences…"
                    : "Public Drive videos ready. Finding epic sequences…"
                operationTask = nil
                scan()
            }
        }
    }

    func importCommandLineVideosIfPresent() {
        let urls = CommandLine.arguments.dropFirst()
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            importVideos(urls, replacing: true)
        }
    }

    func removeSource(_ sourceID: UUID) {
        guard !isBusy else { return }
        previewTask?.cancel()
        sources.removeAll { $0.id == sourceID }
        highlights.removeAll { $0.sourceID == sourceID }
        reindexHighlights()
        if sources.isEmpty {
            player.pause()
            player.replaceCurrentItem(with: nil)
            preview = nil
            preferredExportDirectory = nil
            replacePublicDriveTemporaryDirectory(with: nil)
            publicDriveFolderName = nil
            status = "Import several gameplay videos to begin."
        } else if sources.allSatisfy({ !$0.samples.isEmpty }) {
            recut()
        } else {
            status = "Source removed. Scan again to rebuild the montage."
        }
    }

    func scan() {
        guard !sources.isEmpty, !isBusy else { return }
        operationTask?.cancel()
        operationTask = Task {
            isBusy = true
            progress = 0
            status = "Scanning sound, motion, and scene changes…"
            let sourceCount = sources.count

            do {
                for index in sources.indices {
                    try Task.checkCancellation()
                    if sources[index].scannedQuality == detection.scanQuality,
                       !sources[index].samples.isEmpty {
                        progress = Double(index + 1) / Double(sourceCount)
                        continue
                    }

                    let source = sources[index]
                    let base = Double(index) / Double(sourceCount)
                    let span = 1 / Double(sourceCount)
                    status = "Scanning \(index + 1) of \(sourceCount): \(source.name)"
                    let result = try await VideoAnalyzer.analyze(
                        source: source,
                        quality: detection.scanQuality
                    ) { [weak self] localProgress in
                        Task { @MainActor in
                            self?.progress = base + localProgress * span
                        }
                    }
                    sources[index].samples = result.samples
                    sources[index].scannedQuality = detection.scanQuality
                    sources[index].audioWarning = result.audioWarning
                    progress = Double(index + 1) / Double(sourceCount)
                }

                recut()
                let audioWarnings = sources.filter { $0.audioWarning != nil }.count
                let warningSuffix = audioWarnings > 0
                    ? " \(audioWarnings) source(s) used visual-only fallback."
                    : ""
                let driveSuffix = isPublicDriveFlow
                    ? " Imported from public Drive; the improved Reel is ready to export locally."
                    : ""
                status = "Built \(highlights.count) epic sequences from \(selectedSourceCount) source videos.\(warningSuffix)\(driveSuffix)"
            } catch is CancellationError {
                status = "Scan cancelled. Imported footage is unchanged."
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
            progress = 0
        }
    }

    func recut() {
        guard sources.contains(where: { !$0.samples.isEmpty }) else {
            status = "Run the scan before rebuilding highlights."
            return
        }
        let result = HighlightDetector.detect(sources: sources, settings: detection)
        highlights = result.highlights
        for index in sources.indices {
            sources[index].scoredSamples = result.scoredBySource[sources[index].id] ?? []
        }
        reindexHighlights()
        refreshPreview()
    }

    func refreshPreview() {
        previewTask?.cancel()
        guard !highlights.isEmpty else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            preview = nil
            isPlaying = false
            return
        }

        let sourceSnapshot = sources
        let highlightSnapshot = highlights
        let renderSnapshot = render
        previewTask = Task { [weak self] in
            do {
                let built = try await ReelBuilder.build(
                    sources: sourceSnapshot,
                    highlights: highlightSnapshot,
                    settings: renderSnapshot
                )
                try Task.checkCancellation()
                guard let self else { return }
                self.preview = built
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                self.player.replaceCurrentItem(with: item)
                await self.player.seek(to: .zero)
                try Task.checkCancellation()
                self.isPlaying = false
            } catch is CancellationError {
                return
            } catch {
                self?.status = "Preview could not be built: \(error.localizedDescription)"
            }
        }
    }

    func togglePlayback() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if player.currentTime() >= (preview?.duration ?? .zero) - CMTime(seconds: 0.08, preferredTimescale: 600) {
                Task {
                    await player.seek(to: .zero)
                    player.play()
                    isPlaying = true
                }
                return
            }
            player.play()
            isPlaying = true
        }
    }

    func restartPlayback() {
        player.pause()
        isPlaying = false
        Task {
            await player.seek(to: .zero)
        }
    }

    func moveHighlight(_ id: UUID, offset: Int) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard highlights.indices.contains(index), highlights.indices.contains(destination) else { return }
        highlights.swapAt(index, destination)
        reindexHighlights()
        refreshPreview()
    }

    func removeHighlight(_ id: UUID) {
        guard highlights.contains(where: { $0.id == id }) else { return }
        highlights.removeAll { $0.id == id }
        refreshPreview()
        status = "Sequence removed. \(highlights.count) remain."
    }

    func clampHighlight(_ id: UUID) {
        guard let index = highlights.firstIndex(where: { $0.id == id }),
              let source = sources.first(where: { $0.id == highlights[index].sourceID }) else {
            return
        }
        highlights[index].start = min(
            max(0, highlights[index].start),
            max(0, source.duration - 0.5)
        )
        highlights[index].end = min(
            source.duration,
            max(highlights[index].start + 0.5, highlights[index].end)
        )
        highlights[index].peak = min(
            highlights[index].end,
            max(highlights[index].start, highlights[index].peak)
        )
    }

    func chooseExportLocation() {
        guard !highlights.isEmpty, !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Export vertical gameplay montage"
        panel.prompt = "Export Reel"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = preferredExportDirectory
        panel.nameFieldStringValue = isPublicDriveFlow
            ? "ReelForge-\(publicDriveFolderName ?? "Public-Drive")-Montage.mp4"
            : "ReelForge-\(sources.count)-source-montage.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url)
    }

    func export(to url: URL) {
        guard !highlights.isEmpty, !isBusy else { return }
        operationTask?.cancel()
        operationTask = Task {
            isBusy = true
            progress = 0
            status = "Building \(render.quality.label) vertical montage…"
            do {
                let built = try await ReelBuilder.build(
                    sources: sources,
                    highlights: highlights,
                    settings: render
                )
                progress = 0.2
                status = "Rendering with high-quality Lanczos scaling…"
                try await ReelExporter.export(built, to: url)
                progress = 1
                lastExportURL = url
                preferredExportDirectory = url.deletingLastPathComponent()
                status = "Export complete: \(url.lastPathComponent)"
            } catch is CancellationError {
                status = "Export cancelled."
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
            progress = 0
        }
    }

    func revealLastExport() {
        guard let lastExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
    }

    func cancelOperation() {
        operationTask?.cancel()
    }

    func source(for highlight: Highlight) -> VideoSource? {
        sources.first { $0.id == highlight.sourceID }
    }

    private func reindexHighlights() {
        let indexes = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) })
        for index in highlights.indices {
            highlights[index].sourceIndex = indexes[highlights[index].sourceID] ?? highlights[index].sourceIndex
        }
    }

    private func replacePublicDriveTemporaryDirectory(with directory: URL?) {
        let previous = publicDriveTemporaryDirectory
        publicDriveTemporaryDirectory = directory
        if let previous, previous != directory {
            removeOwnedTemporaryDirectory(previous)
        }
    }

    private func removeOwnedTemporaryDirectory(_ directory: URL) {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let candidate = directory.standardizedFileURL
        let rootComponents = temporaryRoot.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents,
              candidate.lastPathComponent.hasPrefix("ReelForge-PublicDrive-") else {
            return
        }
        try? FileManager.default.removeItem(at: candidate)
    }
}

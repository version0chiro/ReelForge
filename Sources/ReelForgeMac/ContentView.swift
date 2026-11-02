import AVKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.045, blue: 0.065), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 0) {
                sourceRail
                    .frame(width: 270)
                Divider().overlay(Color.white.opacity(0.08))
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Color.white.opacity(0.08))
                controlRail
                    .frame(width: 320)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1_160, minHeight: 760)
        .onAppear {
            model.importCommandLineVideosIfPresent()
        }
    }

    private var sourceRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.lime.opacity(0.13))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.lime.opacity(0.35)))
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.lime)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ReelForge")
                        .font(.system(size: 17, weight: .bold))
                    Text("NATIVE GAMEPLAY CUTTER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .tracking(1.1)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SOURCE BIN")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.lime)
                    Text("\(model.sources.count) videos · \(model.totalFootageDuration.reelTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.chooseVideos()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add gameplay videos")
            }

            if let folderName = model.publicDriveFolderName {
                Label(
                    "PUBLIC DRIVE · \(folderName)",
                    systemImage: "cloud.fill"
                )
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.cyan)
                .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("PUBLIC GOOGLE DRIVE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lime)
                TextField(
                    "Paste public folder URL",
                    text: $model.publicDriveFolderURL
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    model.importPublicDriveFolder()
                }
                Button {
                    model.importPublicDriveFolder()
                } label: {
                    Label("Import & improve folder", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.lime)
                .foregroundStyle(.black)
                .disabled(
                    model.publicDriveFolderURL.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty || model.isBusy
                )
                Text("Folder must use “Anyone with the link”. MP4, MOV, and M4V are downloaded temporarily.")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(panelBackground)

            if model.sources.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.lime.opacity(0.7))
                    Text("Or combine gameplay already stored on this Mac.")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose videos on this Mac") {
                        model.chooseVideos()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .background(panelBackground)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                            sourceCard(source, index: index)
                        }
                    }
                }
                Button("Replace with local videos") {
                    model.chooseVideos(replacing: true)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.2))
    }

    private func sourceCard(_ source: VideoSource, index: Int) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                if let thumbnail = source.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.04)
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.secondary)
                }
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .padding(4)
                    .background(Color.black.opacity(0.7))
            }
            .frame(width: 64, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text("\(source.duration.reelTime) · \(source.resolutionLabel)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                Label(
                    source.samples.isEmpty ? "Not scanned" : "Signals ready",
                    systemImage: source.samples.isEmpty ? "circle.dotted" : "checkmark.circle.fill"
                )
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(source.samples.isEmpty ? Color.secondary : Color.lime)
            }
            Spacer(minLength: 2)
            Button {
                model.removeSource(source.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(panelBackground)
    }

    private var editor: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VERTICAL OUTPUT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.lime)
                    Text("Epic sequence preview")
                        .font(.title2.bold())
                }
                Spacer()
                stat("SOURCES", "\(model.selectedSourceCount)")
                stat("SEQUENCES", "\(model.highlights.count)")
                stat("REEL", model.reelDuration.reelTime)
            }

            HStack(alignment: .center, spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.black)
                        .shadow(color: .black.opacity(0.55), radius: 28, y: 18)
                    if model.highlights.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles.tv")
                                .font(.system(size: 34))
                                .foregroundStyle(Color.lime.opacity(0.6))
                            Text(model.sources.isEmpty ? "Import gameplay" : "Scan to build your Reel")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VideoPlayer(player: model.player)
                            .clipShape(RoundedRectangle(cornerRadius: 23))
                    }
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .aspectRatio(9 / 16, contentMode: .fit)
                .frame(maxHeight: 490)

                VStack(alignment: .leading, spacing: 16) {
                    Text("The preview and export use the same custom compositor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    qualityCallout
                    HStack {
                        Button {
                            model.restartPlayback()
                        } label: {
                            Image(systemName: "backward.end.fill")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            model.togglePlayback()
                        } label: {
                            Label(
                                model.isPlaying ? "Pause" : "Play Reel",
                                systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.lime)
                        .foregroundStyle(.black)
                    }
                    Button("Refresh preview after edits") {
                        model.refreshPreview()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.highlights.isEmpty)
                }
                .frame(width: 210)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(18)
            .background(panelBackground)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("EDIT DECISION LIST")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.lime)
                        Text("Montage sequence")
                            .font(.headline)
                    }
                    Spacer()
                    Text("Trim, reorder, remove, or override framing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if model.highlights.isEmpty {
                    Text("No detected sequences yet.")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(Array(model.highlights.enumerated()), id: \.element.id) { index, highlight in
                                HighlightCard(
                                    highlight: safeElementBinding(
                                        fallback: highlight,
                                        elements: $model.highlights,
                                        id: \.id
                                    ),
                                    index: index,
                                    isLast: index == model.highlights.count - 1,
                                    sourceDuration: model.source(for: highlight)?.duration ?? highlight.end,
                                    moveLeft: { model.moveHighlight(highlight.id, offset: -1) },
                                    moveRight: { model.moveHighlight(highlight.id, offset: 1) },
                                    remove: { model.removeHighlight(highlight.id) },
                                    clamp: { model.clampHighlight(highlight.id) }
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .padding(16)
            .background(panelBackground)
        }
        .padding(20)
    }

    private var controlRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CUT CONTROLS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.lime)
                    Text("Shape the montage")
                        .font(.title3.bold())
                    Text("Sequence scoring favors sustained action, not a single noisy frame.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Group {
                    controlPicker("Target length", selection: $model.detection.targetDuration) {
                        Text("7 sec").tag(7.0)
                        Text("15 sec").tag(15.0)
                        Text("30 sec").tag(30.0)
                        Text("45 sec").tag(45.0)
                        Text("60 sec").tag(60.0)
                    }
                    controlPicker("Cut order", selection: $model.detection.order) {
                        ForEach(ReelOrder.allCases) { Text($0.label).tag($0) }
                    }
                    slider(
                        "Sequence length",
                        value: $model.detection.sequenceDuration,
                        range: 1.5...7,
                        label: "\(String(format: "%.1f", model.detection.sequenceDuration))s"
                    )
                    slider(
                        "Detection mix",
                        value: $model.detection.audioWeight,
                        range: 0...1,
                        label: "\(Int(model.detection.audioWeight * 100))% sound"
                    )
                    slider(
                        "Sensitivity",
                        value: $model.detection.sensitivity,
                        range: 0...1,
                        label: "\(Int(model.detection.sensitivity * 100))%"
                    )
                    controlPicker("Scan detail", selection: $model.detection.scanQuality) {
                        ForEach(ScanQuality.allCases) { Text($0.label).tag($0) }
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))
                Text("VERTICAL RENDER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lime)
                controlPicker("Framing", selection: $model.render.framing) {
                    ForEach(FramingMode.allCases) { Text($0.label).tag($0) }
                }
                controlPicker("Output", selection: $model.render.quality) {
                    ForEach(OutputQuality.allCases) { Text($0.label).tag($0) }
                }
                slider(
                    "Action tracking",
                    value: $model.render.cropStrength,
                    range: 0...1,
                    label: "\(Int(model.render.cropStrength * 100))%"
                )
                slider(
                    "Crop bias",
                    value: $model.render.cropBias,
                    range: -1...1,
                    label: model.render.cropBias == 0 ? "Center" : String(format: "%+.0f%%", model.render.cropBias * 100)
                )

                Button {
                    if model.sources.allSatisfy({ !$0.samples.isEmpty && $0.scannedQuality == model.detection.scanQuality }) {
                        model.recut()
                    } else {
                        model.scan()
                    }
                } label: {
                    Label(
                        model.highlights.isEmpty ? "Find epic sequences" : "Re-cut montage",
                        systemImage: "sparkles"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.lime)
                .foregroundStyle(.black)
                .disabled(model.sources.isEmpty || model.isBusy)

                if model.isBusy {
                    ProgressView(value: model.progress)
                        .tint(Color.lime)
                    Button("Cancel operation") {
                        model.cancelOperation()
                    }
                    .buttonStyle(.bordered)
                }

                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

                Button {
                    model.chooseExportLocation()
                } label: {
                    Label(
                        model.isPublicDriveFlow
                            ? "Export improved Reel"
                            : "Export vertical montage",
                        systemImage: "square.and.arrow.down"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.highlights.isEmpty || model.isBusy)

                if model.lastExportURL != nil {
                    Button("Reveal last export in Finder") {
                        model.revealLastExport()
                    }
                    .buttonStyle(.borderless)
                }

                Label(
                    model.isPublicDriveFlow
                        ? "Public videos are temporary. No Google sign-in or upload."
                        : "Footage stays on this Mac. No upload or account.",
                    systemImage: "lock.shield"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color.black.opacity(0.2))
    }

    private var qualityCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("HQ native scaling", systemImage: "wand.and.rays")
                .font(.caption.bold())
                .foregroundStyle(Color.lime)
            Text("Lanczos scaling + light detail recovery. Adaptive mode preserves low-res landscape footage with a blurred full-frame layout.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.lime.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.lime.opacity(0.14)))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
        }
        .frame(minWidth: 64, alignment: .trailing)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        label: String
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lime)
            }
            Slider(value: value, in: range)
                .tint(Color.lime)
        }
    }

    private func controlPicker<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title).font(.caption.bold())
            Spacer()
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .frame(width: 150)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(red: 0.07, green: 0.085, blue: 0.115).opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.075)))
    }

}

private struct HighlightCard: View {
    @Binding var highlight: Highlight
    let index: Int
    let isLast: Bool
    let sourceDuration: Double
    let moveLeft: () -> Void
    let moveRight: () -> Void
    let remove: () -> Void
    let clamp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("CUT \(String(format: "%02d", index + 1))")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .foregroundStyle(.black)
                    .background(Color.lime, in: RoundedRectangle(cornerRadius: 5))
                Spacer()
                Text("EPIC \(Int(highlight.score * 100))")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("SRC \(String(format: "%02d", highlight.sourceIndex + 1)) · \(highlight.sourceName)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.cyan)
                .lineLimit(1)
            Text("\(highlight.start.reelTime) — \(highlight.end.reelTime)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            HStack(spacing: 5) {
                ForEach(highlight.reasons, id: \.self) { reason in
                    Text(reason.uppercased())
                        .font(.system(size: 6, weight: .bold, design: .monospaced))
                        .padding(4)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            ProgressView(value: highlight.score)
                .tint(Color.lime)

            HStack {
                Text("IN").font(.system(size: 7, weight: .bold))
                TextField("In", value: $highlight.start, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .onSubmit(clamp)
                Text("OUT").font(.system(size: 7, weight: .bold))
                TextField("Out", value: $highlight.end, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .onSubmit(clamp)
            }
            Picker("Framing", selection: $highlight.framingOverride) {
                Text("Use global framing").tag(FramingMode?.none)
                ForEach(FramingMode.allCases) { mode in
                    Text(mode.label).tag(Optional(mode))
                }
            }
            .font(.caption2)

            HStack {
                Button(action: moveLeft) { Image(systemName: "arrow.left") }
                    .disabled(index == 0)
                Button(action: moveRight) { Image(systemName: "arrow.right") }
                    .disabled(isLast)
                Spacer()
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 225)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
        )
    }
}

private extension Color {
    static let lime = Color(red: 0.718, green: 1, blue: 0.282)
}

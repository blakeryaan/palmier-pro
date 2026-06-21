import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum ExportMode: String, CaseIterable, Identifiable {
    case video = "Video (.mp4)"
    case xml = "Timeline (.xml)"
    case hotfeditorProject = "HoTF Editorject (.hotf)"

    var id: String { rawValue }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case h265 = "H.265"
    case prores = "ProRes"

    var id: String { rawValue }
}

struct ExportView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var service = ExportService()
    @State private var mode: ExportMode = .video
    @State private var codec: VideoCodec = .h264
    @State private var resolution: ExportResolution = .r1080p
    @State private var preview: NSImage?
    @State private var hotfeditorResult: String?
    @State private var hotfeditorSummary: (collect: Int, missing: Int, bytes: Int64) = (0, 0, 0)
    @State private var isSendingToAgent = false
    @State private var agentSendStatus: String?
    @State private var showSaveTemplate = false
    @State private var templateName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                settingsPanel
                    .frame(width: 360)
                previewPanel
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            bottomBar
        }
        .frame(width: 860, height: 560)
        .presentationBackground {
            AppTheme.Background.surfaceColor.opacity(0.85)
                .background(.ultraThinMaterial)
        }
        .task {
            loadPreview()
            hotfeditorSummary = computeHoTFEditorSummary()
        }
    }

    private func panelHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.title2, weight: .light))
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Preview (right)

    private var previewPanel: some View {
        ZStack {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film")
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.baseColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .padding(AppTheme.Spacing.xl)
    }

    // MARK: - Settings (left)

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            panelHeader("Export")

            VStack(alignment: .leading, spacing: 0) {
            // Settings rows
            VStack(spacing: 0) {
                settingRow(label: "Format") {
                    Picker("", selection: $mode) {
                        ForEach(ExportMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .labelsHidden()
                }

                Divider().opacity(0.2)

                switch mode {
                case .video:
                    settingRow(label: "Codec") {
                        Picker("", selection: $codec) {
                            ForEach(VideoCodec.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider().opacity(0.2)

                    settingRow(label: "Resolution") {
                        Picker("", selection: $resolution) {
                            ForEach(ExportResolution.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider().opacity(0.2)

                    settingRow(label: "Frame Rate") {
                        Text("\(editor.timeline.fps) fps")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }

                case .xml:
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Exports your timeline as XML for use in other editors.")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)

                        Text("Works with DaVinci Resolve, Premiere Pro, and Final Cut Pro.")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)

                        Text("Text overlays, flips, and keyframe easing aren't included.")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)

                case .hotfeditorProject:
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Saves a copy of this project with all media bundled inside, so it opens on any machine.")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)

                        if hotfeditorSummary.missing > 0 {
                            Text("\(hotfeditorSummary.missing) media file\(hotfeditorSummary.missing == 1 ? "" : "s") missing — they'll be skipped.")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Status.errorColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)
                }
            }

            // Progress
            if service.isExporting {
                VStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView(value: service.progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(service.progress * 100))%")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .padding(.top, AppTheme.Spacing.md)
            }

            if let error = service.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, AppTheme.Spacing.sm)
            }

            if let hotfeditorResult {
                Text(hotfeditorResult)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.top, AppTheme.Spacing.sm)
            }

            Spacer()
            }
            .padding(AppTheme.Spacing.xl)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            let duration = formatTimecode(frame: editor.timeline.totalFrames, fps: editor.timeline.fps)
            HStack(spacing: AppTheme.Spacing.lg) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "clock")
                    Text(duration)
                }
                switch mode {
                case .video:
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "doc")
                        Text("~\(estimatedFileSize)")
                    }
                    let out = resolution.renderSize(for: CGSize(width: editor.timeline.width, height: editor.timeline.height))
                    Text("\(Int(out.width))×\(Int(out.height))")
                case .xml:
                    Text("\(editor.timeline.width)×\(editor.timeline.height)")
                case .hotfeditorProject:
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "shippingbox")
                        Text("~\(ByteCountFormatter.string(fromByteCount: hotfeditorSummary.bytes, countStyle: .file))")
                    }
                }
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)

            Spacer()

            if let status = agentSendStatus {
                Text(status)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(1)
            }

            Button("Cancel") { editor.showExportDialog = false }
                .keyboardShortcut(.cancelAction)

            if let project = HoTFOpenJobs.shared.project(forPath: editor.projectURL?.path) {
                Button("Save as Template") {
                    templateName = project.templateName ?? project.name ?? "Untitled Template"
                    showSaveTemplate = true
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .alert("Save as Template", isPresented: $showSaveTemplate) {
                    TextField("Template name", text: $templateName)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") { saveTemplate(project) }
                } message: {
                    Text("Saves this edited structure as a reusable Mode C template.")
                }

                Button(isSendingToAgent ? "Sending…" : "Send to Agent Render") { sendToAgent(project) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(isSendingToAgent || service.isExporting)
            }

            Button("Export") { startExport() }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(service.isExporting)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    private func saveTemplate(_ project: HoTFProject) {
        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            let template = HoTFJobImporter.dialedRecipe(from: editor, job: project.asEditorJob()).template
            do {
                try await HoTFMailbox.shared.saveAsTemplate(name: name, template: template, sourceProjectId: project.id)
                agentSendStatus = "Saved template “\(name)”"
            } catch {
                agentSendStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func sendToAgent(_ project: HoTFProject) {
        isSendingToAgent = true
        agentSendStatus = nil
        Task {
            defer { isSendingToAgent = false }
            if let doc = HoTFOpenJobs.shared.doc(for: project.id) {
                await HoTFJobImporter.persist(doc)
            }
            let dialed = HoTFJobImporter.dialedRecipe(from: editor, job: project.asEditorJob())
            do {
                try await HoTFMailbox.shared.sendProjectForRender(project, dialed: dialed)
                await HoTFMailbox.shared.refreshRenderQueue()
                editor.showExportDialog = false
            } catch {
                agentSendStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func settingRow<Control: View>(label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            control()
        }
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var estimatedFileSize: String {
        let seconds = Double(editor.timeline.totalFrames) / Double(max(1, editor.timeline.fps))
        let bytesPerSec: Double = switch (codec, resolution) {
        case (.h264, .r720p):    0.85e6
        case (.h264, .r1080p):   1.3e6
        case (.h264, .r4k):      2.8e6
        case (.h265, .r720p):    0.45e6
        case (.h265, .r1080p):   0.65e6
        case (.h265, .r4k):      2.2e6
        case (.prores, .r720p):  8.0e6
        case (.prores, .r1080p): 18.5e6
        case (.prores, .r4k):    65.0e6
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec * seconds), countStyle: .file)
    }

    private var exportFormat: ExportFormat {
        switch mode {
        case .xml, .hotfeditorProject: .xml   // hotfeditorProject has its own path; never rendered
        case .video:
            switch codec {
            case .h264: .h264
            case .h265: .h265
            case .prores: .prores
            }
        }
    }

    /// Quick estimate for exporting a HoTF Editorject
    private func computeHoTFEditorSummary() -> (collect: Int, missing: Int, bytes: Int64) {
        var collect = 0, missing = 0
        var bytes: Int64 = 0
        for entry in editor.mediaManifest.entries {
            let url: URL? = switch entry.source {
            case .external(let path): URL(fileURLWithPath: path)
            case .project(let rel): editor.projectURL?.appendingPathComponent(rel)
            }
            guard let url, FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
            if case .external = entry.source { collect += 1 }
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (collect, missing, bytes)
    }

    private func loadPreview() {
        for track in editor.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.maximumSize = CGSize(width: 480, height: 270)
                generator.appliesPreferredTrackTransform = true
                let time = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: CMTimeScale(editor.timeline.fps))
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                    if let image {
                        Task { @MainActor in
                            preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                        }
                    }
                }
                return
            }
        }
    }

    private func startExport() {
        if mode == .hotfeditorProject { startHoTFEditorExport(); return }
        let format = exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            format == .xml
                ? .xml
                : (format == .prores ? .movie : .mpeg4Movie)
        ]
        panel.nameFieldStringValue = "export.\(format.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await service.export(
                    timeline: editor.timeline,
                    resolver: editor.mediaResolver,
                    format: format,
                    resolution: resolution,
                    outputURL: url
                )
                if service.error == nil {
                    editor.showExportDialog = false
                }
            }
        }
    }

    private func startHoTFEditorExport() {
        hotfeditorResult = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(Project.typeIdentifier) ?? .package]
        let base = editor.projectURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName
        panel.nameFieldStringValue = "\(base).\(Project.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let report = await service.exportHoTFEditorProject(
                    timeline: editor.timeline,
                    manifest: editor.mediaManifest,
                    generationLog: editor.generationLog,
                    sourceProjectURL: editor.projectURL,
                    outputURL: url
                )
                guard let report, service.error == nil else { return }
                if report.missing.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    editor.showExportDialog = false
                } else {
                    // Keep the dialog open so the user sees what couldn't be included.
                    hotfeditorResult = "Exported, but \(report.missing.count) media file\(report.missing.count == 1 ? "" : "s") were missing and couldn't be included."
                }
            }
        }
    }
}

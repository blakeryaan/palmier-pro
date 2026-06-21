import AppKit
import Foundation

/// Maps a Mode C recipe ⇄ a Palmier Pro project/timeline (the T3 half of the
/// mailbox contract). `open(_:)` builds an editable timeline from a `ready`/`open`
/// job; `dialedRecipe(from:job:)` serializes the dialed timeline back into a
/// recipe for the render worker.
///
/// v1 is a timing/text/framing dial: video clips and text clips map 1:1 to
/// segments in order, so the save-back relies on clip order matching segment
/// order (don't reorder or add/remove clips before approving). Richer edits
/// Remotion can't represent (motion/keyframes) are dropped — the documented seam.
@MainActor
enum HoTFJobImporter {

    struct MediaSlot {
        let assetId: String
        let proxyURL: String?
        let type: ClipType
        let name: String
    }

    static func open(_ job: HoTFEditorJob) async throws {
        _ = try await build(job, show: true)
    }

    /// Headless variant for prefetch — downloads media + writes the project
    /// package without opening a window. Returns the project URL so it can be
    /// cached and opened instantly later.
    static func prepare(_ job: HoTFEditorJob) async throws -> URL {
        try await build(job, show: false).url
    }

    @discardableResult
    private static func build(_ job: HoTFEditorJob, show: Bool) async throws -> (doc: VideoProject, url: URL) {
        let recipe = job.workingRecipe
        let doc = VideoProject()
        let url = uniqueProjectURL(named: job.name ?? recipe.hookText)
        doc.fileURL = url
        doc.fileType = VideoProject.typeIdentifier
        if show {
            doc.makeWindowControllers()
            doc.showWindows()
            NSDocumentController.shared.addDocument(doc)
        }
        try await save(doc, to: url)

        let editor = doc.editorViewModel
        editor.projectURL = url

        let mediaDir = url.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        // 1. Gather the unique media the recipe references.
        let slots = collectMediaSlots(recipe: recipe, manifest: job.mediaManifest ?? [:])

        // 2. Download each proxy into the project and register it as an asset.
        for slot in slots {
            await materialize(slot, into: mediaDir, editor: editor, projectURL: url)
        }

        // 3. Build the timeline and apply it live.
        editor.timeline = buildTimeline(recipe: recipe)
        editor.seedGenerationLogFromAssets()

        try await save(doc, to: url)
        return (doc, url)
    }

    // MARK: - Media collection

    private static func collectMediaSlots(recipe: HoTFRecipe, manifest: HoTFMediaManifestMap) -> [MediaSlot] {
        var seen = Set<String>()
        var slots: [MediaSlot] = []
        let resolution = recipe.resolution

        func add(assetId: String, fallbackURL: String?, type: ClipType, name: String) {
            guard !assetId.isEmpty, !seen.contains(assetId) else { return }
            seen.insert(assetId)
            let proxy = manifest[assetId]?.proxyUrl ?? manifest[assetId]?.fullResUrl ?? fallbackURL
            slots.append(MediaSlot(assetId: assetId, proxyURL: proxy, type: type, name: name))
        }

        for segment in recipe.template.segments {
            switch segment.media {
            case let .brollSlot(slotId, _):
                let ref = resolution.assetRefs?[slotId]
                let assetId = ref?.id ?? slotId
                let fallback = resolution.brollSlots[slotId] ?? ref?.frameIoViewUrl ?? ref?.driveUrl
                add(assetId: assetId, fallbackURL: fallback, type: .video, name: ref?.filename ?? slotId)
            case let .brollFixed(assetUrl):
                add(assetId: stableId(for: assetUrl), fallbackURL: assetUrl, type: .video, name: lastPathComponent(assetUrl))
            case .color:
                continue
            }
        }

        if let audioSlotId = recipe.template.audio.primary.slotId {
            let ref = resolution.assetRefs?[audioSlotId]
            let assetId = ref?.id ?? audioSlotId
            let fallback = resolution.audioSlots[audioSlotId] ?? ref?.frameIoViewUrl ?? ref?.driveUrl
            add(assetId: assetId, fallbackURL: fallback, type: .audio, name: ref?.filename ?? audioSlotId)
        }

        return slots
    }

    private static func materialize(_ slot: MediaSlot, into mediaDir: URL, editor: EditorViewModel, projectURL: URL) async {
        let ext = fileExtension(for: slot.proxyURL, type: slot.type)
        let destURL = mediaDir.appendingPathComponent("\(safeFilename(slot.assetId)).\(ext)")

        var downloaded = false
        if let proxy = slot.proxyURL, let remote = downloadableURL(proxy), remote.scheme?.hasPrefix("http") == true {
            downloaded = await download(remote, to: destURL)
        }

        let source: MediaSource = downloaded
            ? .project(relativePath: "\(Project.mediaDirectoryName)/\(destURL.lastPathComponent)")
            : .external(absolutePath: destURL.path)

        var entry = MediaManifestEntry(
            id: slot.assetId,
            name: slot.name,
            type: slot.type,
            source: source,
            duration: 0,
            generationInput: nil,
            sourceWidth: nil,
            sourceHeight: nil,
            sourceFPS: nil,
            hasAudio: slot.type == .video,
            folderId: nil,
            cachedRemoteURL: slot.proxyURL,
            cachedRemoteURLExpiresAt: slot.proxyURL == nil ? nil : Date().addingTimeInterval(60 * 60 * 24 * 7)
        )
        if editor.mediaManifest.entries.contains(where: { $0.id == entry.id }) { return }
        editor.mediaManifest.entries.append(entry)

        if downloaded, let resolved = editor.mediaResolver.expectedURL(for: slot.assetId) {
            let asset = MediaAsset(entry: entry, resolvedURL: resolved)
            editor.mediaAssets.append(asset)
            await asset.loadMetadata()
            if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == entry.id }) {
                entry.duration = asset.duration
                entry.sourceWidth = asset.sourceWidth
                entry.sourceHeight = asset.sourceHeight
                entry.sourceFPS = asset.sourceFPS
                entry.hasAudio = asset.hasAudio
                editor.mediaManifest.entries[idx] = entry
            }
        }
    }

    /// Google Drive `/file/d/<id>/view` and `open?id=` links serve an HTML
    /// preview page, not the file. Rewrite them to the direct-download endpoint
    /// so the proxy actually lands as media. Non-Drive URLs pass through.
    private static func downloadableURL(_ urlString: String) -> URL? {
        guard let id = driveFileId(urlString) else { return URL(string: urlString) }
        return URL(string: "https://drive.google.com/uc?export=download&id=\(id)&confirm=t")
    }

    private static func driveFileId(_ urlString: String) -> String? {
        guard urlString.contains("drive.google.com") || urlString.contains("docs.google.com") else { return nil }
        if let range = urlString.range(of: "/d/") {
            let id = urlString[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "&" }
            if !id.isEmpty { return String(id) }
        }
        if let items = URLComponents(string: urlString)?.queryItems,
           let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty {
            return id
        }
        return nil
    }

    private static func download(_ remote: URL, to dest: URL) async -> Bool {
        do {
            let (tmp, response) = try await URLSession.shared.download(from: remote)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
            // A Drive virus-scan interstitial comes back as HTML, not media.
            if (response.mimeType ?? "").contains("html") {
                try? FileManager.default.removeItem(at: tmp)
                Log.project.error("HoTF proxy is an HTML page, not media: \(remote.absoluteString)")
                return false
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        } catch {
            Log.project.error("HoTF proxy download failed \(remote.absoluteString): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Timeline build

    static func buildTimeline(recipe: HoTFRecipe) -> Timeline {
        let canvas = recipe.template.canvas
        let fps = max(1, canvas.fps)
        var timeline = Timeline()
        timeline.fps = fps
        timeline.width = canvas.width
        timeline.height = canvas.height
        timeline.settingsConfigured = true

        var videoClips: [Clip] = []
        var textClips: [Clip] = []
        var cursor = 0

        for segment in recipe.template.segments {
            let durationFrames = max(1, Int((segment.durationSec * Double(fps)).rounded()))

            if let assetId = mediaAssetId(for: segment, resolution: recipe.resolution) {
                var clip = Clip(mediaRef: assetId, startFrame: cursor, durationFrames: durationFrames)
                clip.mediaType = .video
                clip.sourceClipType = .video
                clip.trimStartFrame = max(0, segment.startFromFrames ?? 0)
                clip.speed = segment.speed ?? 1.0
                clip.transform = framingTransform(segment.framing)
                videoClips.append(clip)
            }

            if let overlay = segment.text {
                let appear = max(0, overlay.appearAtFrame ?? 0)
                let disappear = overlay.disappearAtFrame ?? durationFrames
                let textDuration = max(1, min(durationFrames, disappear) - appear)
                var textClip = Clip(mediaRef: "", startFrame: cursor + appear, durationFrames: textDuration)
                textClip.mediaType = .text
                textClip.sourceClipType = .text
                textClip.textContent = resolveCopy(overlay.copy, recipe: recipe)
                textClip.textStyle = textStyle(for: overlay)
                textClip.transform = textTransform(position: overlay.position)
                textClips.append(textClip)
            }

            cursor += durationFrames
        }

        var tracks: [Track] = []
        if !videoClips.isEmpty {
            tracks.append(Track(type: .video, clips: videoClips))
        }
        if !textClips.isEmpty {
            tracks.append(Track(type: .text, clips: textClips))
        }
        if let audioId = audioAssetId(for: recipe), cursor > 0 {
            var audioClip = Clip(mediaRef: audioId, startFrame: 0, durationFrames: cursor)
            audioClip.mediaType = .audio
            audioClip.sourceClipType = .audio
            tracks.append(Track(type: .audio, clips: [audioClip]))
        }
        timeline.tracks = tracks
        return timeline
    }

    // MARK: - Save-back

    /// Force-persist the project package (timeline + manifest) to disk — used
    /// before Send for Render so the local .palmier always reflects the edit,
    /// even for edits that didn't route through the undo manager.
    static func persist(_ doc: VideoProject) async {
        guard let url = doc.fileURL else { return }
        doc.updateChangeCount(.changeDone)
        try? await save(doc, to: url)
    }

    static func dialedRecipe(from editor: EditorViewModel, job: HoTFEditorJob) -> HoTFRecipe {
        var recipe = job.workingRecipe
        let fps = Double(max(1, editor.timeline.fps))

        let videoClips = editor.timeline.tracks
            .first(where: { $0.type == .video })?.clips
            .sorted(by: { $0.startFrame < $1.startFrame }) ?? []
        let textClips = editor.timeline.tracks
            .first(where: { $0.type == .text })?.clips
            .sorted(by: { $0.startFrame < $1.startFrame }) ?? []

        var videoIdx = 0
        var textIdx = 0
        var segments = recipe.template.segments

        for i in segments.indices {
            let hasMedia: Bool = {
                if case .color = segments[i].media { return false }
                return true
            }()
            if hasMedia, videoIdx < videoClips.count {
                let clip = videoClips[videoIdx]
                videoIdx += 1
                let durationSec = Double(clip.durationFrames) / fps
                segments[i].t1 = segments[i].t0 + durationSec
                segments[i].startFromFrames = clip.trimStartFrame
                segments[i].speed = clip.speed
                segments[i].framing = updatedFraming(segments[i].framing, transform: clip.transform)
            }
            if segments[i].text != nil, textIdx < textClips.count {
                let clip = textClips[textIdx]
                textIdx += 1
                if let content = clip.textContent { segments[i].text?.copy = content }
                segments[i].text?.position = positionName(for: clip.transform)
            }
        }

        recipe.template.segments = segments
        return recipe
    }

    // MARK: - Mapping helpers

    private static func mediaAssetId(for segment: HoTFSegment, resolution: HoTFSlotResolution) -> String? {
        switch segment.media {
        case let .brollSlot(slotId, _):
            return resolution.assetRefs?[slotId]?.id ?? slotId
        case let .brollFixed(assetUrl):
            return stableId(for: assetUrl)
        case .color:
            return nil
        }
    }

    private static func audioAssetId(for recipe: HoTFRecipe) -> String? {
        guard let slotId = recipe.template.audio.primary.slotId else { return nil }
        return recipe.resolution.assetRefs?[slotId]?.id ?? slotId
    }

    private static func resolveCopy(_ copy: String, recipe: HoTFRecipe) -> String {
        var result = copy
        let hook = recipe.hookText.isEmpty ? (recipe.resolution.literals["hook"] ?? "") : recipe.hookText
        for token in ["{{hook}}", "{{ hook }}"] {
            result = result.replacingOccurrences(of: token, with: hook)
        }
        for (key, value) in recipe.resolution.literals {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
            result = result.replacingOccurrences(of: "{{ \(key) }}", with: value)
        }
        return result
    }

    private static func textStyle(for overlay: HoTFTextOverlay) -> TextStyle {
        var style = TextStyle()
        if let size = overlay.fontSizeOverride { style.fontSize = size }
        switch overlay.position {
        case let p where p.hasSuffix("-left"): style.alignment = .left
        case let p where p.hasSuffix("-right"): style.alignment = .right
        default: style.alignment = .center
        }
        return style
    }

    /// Map one of the 9 named anchors to a normalized centre point.
    private static func textTransform(position: String) -> Transform {
        let (cx, cy) = anchorCenter(position)
        return Transform(center: (cx, cy), width: 0.9, height: 0.28)
    }

    private static func anchorCenter(_ position: String) -> (Double, Double) {
        let cx: Double
        if position.contains("left") { cx = 0.28 }
        else if position.contains("right") { cx = 0.72 }
        else { cx = 0.5 }
        let cy: Double
        if position.contains("top") { cy = 0.16 }
        else if position.contains("bottom") { cy = 0.84 }
        else { cy = 0.5 }
        return (cx, cy)
    }

    private static func positionName(for transform: Transform) -> String {
        let vertical: String
        if transform.centerY < 0.34 { vertical = "top" }
        else if transform.centerY > 0.66 { vertical = "bottom" }
        else { vertical = "middle" }
        let horizontal: String
        if transform.centerX < 0.4 { horizontal = "left" }
        else if transform.centerX > 0.6 { horizontal = "right" }
        else { horizontal = "center" }
        return "\(vertical)-\(horizontal)"
    }

    private static func framingTransform(_ framing: HoTFSegmentFraming?) -> Transform {
        guard let pos = framing?.objectPosition else { return Transform() }
        let (cx, cy) = parseObjectPosition(pos)
        return Transform(center: (cx, cy), width: 1, height: 1)
    }

    private static func updatedFraming(_ framing: HoTFSegmentFraming?, transform: Transform) -> HoTFSegmentFraming {
        var next = framing ?? HoTFSegmentFraming()
        let x = Int((transform.centerX * 100).rounded())
        let y = Int((transform.centerY * 100).rounded())
        next.objectPosition = "\(x)% \(y)%"
        return next
    }

    private static func parseObjectPosition(_ value: String) -> (Double, Double) {
        let parts = value.split(separator: " ").map { $0.replacingOccurrences(of: "%", with: "") }
        let x = parts.count > 0 ? (Double(parts[0]).map { $0 / 100 } ?? 0.5) : 0.5
        let y = parts.count > 1 ? (Double(parts[1]).map { $0 / 100 } ?? 0.5) : 0.5
        return (x, y)
    }

    // MARK: - File helpers

    private static func uniqueProjectURL(named rawName: String) -> URL {
        let base = Project.storageDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let stem = safeFilename(rawName.isEmpty ? Project.defaultProjectName : rawName)
        var candidate = base.appendingPathComponent("\(stem).\(Project.fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(stem) \(n).\(Project.fileExtension)")
            n += 1
        }
        return candidate
    }

    private static func save(_ doc: VideoProject, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            doc.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func stableId(for value: String) -> String {
        "fixed-\(abs(value.hashValue))"
    }

    private static func lastPathComponent(_ urlString: String) -> String {
        URL(string: urlString)?.lastPathComponent ?? "asset"
    }

    private static func fileExtension(for urlString: String?, type: ClipType) -> String {
        if let urlString, let url = URL(string: urlString) {
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 4 { return ext }
        }
        return type == .audio ? "mp3" : "mp4"
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
        let cleaned = String(value.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "hotf-job" : String(cleaned.prefix(80))
    }
}

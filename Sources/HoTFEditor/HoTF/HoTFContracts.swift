import Foundation

// Codable mirror of the Reeve ↔ editor mailbox contract
// (`docs/REEVE_MAILBOX_CONTRACT.md`, TS source `trial-reel-engine/src/ModeC/types.ts`).
// Field names match the JSON the Trial Reel Engine writes. Unknown keys (editBrief,
// notes, …) are dropped on decode and not round-tripped — the render worker only
// needs template + resolution + hookText from the dialed recipe.

struct HoTFCanvas: Codable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
}

struct HoTFPacing: Codable, Equatable {
    var avgCutSec: Double
    var style: String
}

/// `Segment.media` — discriminated on `kind`.
enum HoTFSegmentMedia: Codable, Equatable {
    case brollSlot(slotId: String, tagQuery: [String])
    case brollFixed(assetUrl: String)
    case color(hex: String)

    private enum CodingKeys: String, CodingKey { case kind, slotId, tagQuery, assetUrl, hex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "broll_slot":
            self = .brollSlot(
                slotId: try c.decode(String.self, forKey: .slotId),
                tagQuery: (try? c.decode([String].self, forKey: .tagQuery)) ?? []
            )
        case "broll_fixed":
            self = .brollFixed(assetUrl: try c.decode(String.self, forKey: .assetUrl))
        case "color":
            self = .color(hex: (try? c.decode(String.self, forKey: .hex)) ?? "#000000")
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown media kind \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .brollSlot(slotId, tagQuery):
            try c.encode("broll_slot", forKey: .kind)
            try c.encode(slotId, forKey: .slotId)
            try c.encode(tagQuery, forKey: .tagQuery)
        case let .brollFixed(assetUrl):
            try c.encode("broll_fixed", forKey: .kind)
            try c.encode(assetUrl, forKey: .assetUrl)
        case let .color(hex):
            try c.encode("color", forKey: .kind)
            try c.encode(hex, forKey: .hex)
        }
    }

    /// slotId for a slot-backed segment, else nil.
    var slotId: String? {
        if case let .brollSlot(slotId, _) = self { return slotId }
        return nil
    }
}

struct HoTFTextOverlay: Codable, Equatable {
    var copy: String
    var position: String
    var fontSizeOverride: Double?
    var appearAtFrame: Int?
    var disappearAtFrame: Int?
}

struct HoTFSegmentFraming: Codable, Equatable {
    var fit: String?
    var objectPosition: String?
    var precomposedMediaTop: Double?
    var headerTop: Double?
}

struct HoTFSegment: Codable, Equatable {
    var id: String
    var t0: Double
    var t1: Double
    var media: HoTFSegmentMedia
    var framing: HoTFSegmentFraming?
    var startFromFrames: Int?
    var text: HoTFTextOverlay?
    var speed: Double?

    var durationSec: Double { max(0, t1 - t0) }
}

/// `AudioPlan.primary` — discriminated on `kind`.
enum HoTFAudioPrimary: Codable, Equatable {
    case voiceoverSlot(slotId: String)
    case musicSlot(slotId: String, tagQuery: [String])
    case silent

    private enum CodingKeys: String, CodingKey { case kind, slotId, tagQuery }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "voiceover_slot":
            self = .voiceoverSlot(slotId: try c.decode(String.self, forKey: .slotId))
        case "music_slot":
            self = .musicSlot(
                slotId: try c.decode(String.self, forKey: .slotId),
                tagQuery: (try? c.decode([String].self, forKey: .tagQuery)) ?? []
            )
        default:
            self = .silent
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .voiceoverSlot(slotId):
            try c.encode("voiceover_slot", forKey: .kind)
            try c.encode(slotId, forKey: .slotId)
        case let .musicSlot(slotId, tagQuery):
            try c.encode("music_slot", forKey: .kind)
            try c.encode(slotId, forKey: .slotId)
            try c.encode(tagQuery, forKey: .tagQuery)
        case .silent:
            try c.encode("silent", forKey: .kind)
        }
    }

    var slotId: String? {
        switch self {
        case let .voiceoverSlot(slotId): return slotId
        case let .musicSlot(slotId, _): return slotId
        case .silent: return nil
        }
    }
}

struct HoTFAudioPlan: Codable, Equatable {
    var primary: HoTFAudioPrimary
}

struct HoTFSlotAssetRef: Codable, Equatable {
    var id: String?
    var driveUrl: String?
    var frameIoViewUrl: String?
    var filename: String?
    var type: String?
}

struct HoTFSlotResolution: Codable, Equatable {
    var brollSlots: [String: String]
    var audioSlots: [String: String]
    var literals: [String: String]
    var assetRefs: [String: HoTFSlotAssetRef]?
}

struct HoTFFormatTemplate: Codable, Equatable {
    var id: String
    var version: Int
    var name: String
    var formatKind: String?
    var sourceUrl: String?
    var durationSec: Double
    var canvas: HoTFCanvas
    var segments: [HoTFSegment]
    var audio: HoTFAudioPlan
    var requiredAssetTags: [String]
    var vibeTags: [String]
    var pacing: HoTFPacing
}

/// The Mode C recipe carried in `recipe` / `dialed`.
struct HoTFRecipe: Codable, Equatable {
    var template: HoTFFormatTemplate
    var resolution: HoTFSlotResolution
    var hookText: String

    /// Empty stand-in so a Mode D clip job can keep the non-optional `recipe`
    /// field without carrying a real Mode C recipe.
    static let placeholder = HoTFRecipe(
        template: HoTFFormatTemplate(
            id: "", version: 0, name: "", formatKind: nil, sourceUrl: nil, durationSec: 0,
            canvas: HoTFCanvas(width: 0, height: 0, fps: 0), segments: [],
            audio: HoTFAudioPlan(primary: .silent), requiredAssetTags: [], vibeTags: [],
            pacing: HoTFPacing(avgCutSec: 0, style: "")
        ),
        resolution: HoTFSlotResolution(brollSlots: [:], audioSlots: [:], literals: [:], assetRefs: nil),
        hookText: ""
    )
}

/// Which import path a job's `recipe`/`dialed` takes. Mode C recipes have no
/// `kind` (or `kind:"modeC"`); a Mode D clip job has `kind:"clip"` and carries a
/// full native editor timeline that opens losslessly.
enum HoTFRecipeKind: Equatable { case modeC, clip }

/// A Mode D clip recipe: `{ "kind":"clip", "timeline":<native Timeline JSON>,
/// "fps":Int, "width":Int, "height":Int }`. `timelineData` is the editor's OWN
/// serialized `Timeline` — byte-identical to what the `.hotf` package stores —
/// so importing decodes it straight into the native `Timeline`, no field mapping.
struct HoTFClipRecipe: Equatable {
    var timelineData: Data
    var fps: Int
    var width: Int
    var height: Int

    /// Decode the carried native timeline. Same shape `HeadlessExport.loadProject`
    /// and `VideoProject.read` consume.
    func decodedTimeline() throws -> Timeline {
        try JSONDecoder().decode(Timeline.self, from: timelineData)
    }

    /// Re-encode for write-back into `dialed`: `{kind:clip, timeline, fps, width, height}`.
    func encodedRecipeObject() throws -> [String: Any] {
        [
            "kind": "clip",
            "timeline": try JSONSerialization.jsonObject(with: timelineData),
            "fps": fps,
            "width": width,
            "height": height,
        ]
    }

    /// Decode from a raw recipe JSON object iff it is `kind:"clip"`. Returns nil
    /// for Mode C recipes (no `kind`, or any other value).
    static func from(rawRecipe object: Any?) -> HoTFClipRecipe? {
        guard let dict = object as? [String: Any], dict["kind"] as? String == "clip" else { return nil }
        guard let timeline = dict["timeline"], JSONSerialization.isValidJSONObject(timeline),
              let timelineData = try? JSONSerialization.data(withJSONObject: timeline) else { return nil }
        let fps = (dict["fps"] as? NSNumber)?.intValue ?? 30
        let width = (dict["width"] as? NSNumber)?.intValue ?? 1920
        let height = (dict["height"] as? NSNumber)?.intValue ?? 1080
        return HoTFClipRecipe(timelineData: timelineData, fps: fps, width: width, height: height)
    }
}

/// One `media_manifest` entry: same id, two files.
struct HoTFMediaManifestEntry: Codable, Equatable {
    var proxyUrl: String?
    var fullResUrl: String?
}

typealias HoTFMediaManifestMap = [String: HoTFMediaManifestEntry]

/// Decodes any JSON sub-tree into a Foundation `Any`, so we can peek at a
/// recipe's `kind` discriminator before committing to a Mode C decode.
private struct RawJSON: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode([String: RawJSON].self) { value = v.mapValues(\.value) }
        else if let v = try? c.decode([RawJSON].self) { value = v.map(\.value) }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else { value = NSNull() }
    }
}

/// One row of `editor_jobs`.
struct HoTFEditorJob: Equatable, Identifiable {
    var id: String
    var clientId: String?
    var clientSlug: String?
    var name: String?
    var status: String
    /// Mode C recipe. For a Mode D clip job this is `HoTFRecipe.placeholder`.
    var recipe: HoTFRecipe
    var mediaManifest: HoTFMediaManifestMap?
    /// Mode C dialed recipe. Nil for clip jobs (see `dialedClipRecipe`).
    var dialed: HoTFRecipe?
    var outputUrl: String?
    var notionRenderPageId: String?
    var claimedBy: String?
    var createdAt: String?

    /// `.clip` when `recipe.kind == "clip"`, else `.modeC`.
    var recipeKind: HoTFRecipeKind = .modeC
    /// The Mode D clip payload (native timeline + dims), present iff `recipeKind == .clip`.
    var clipRecipe: HoTFClipRecipe?
    /// The dialed clip payload, when a clip job was already dialed.
    var dialedClipRecipe: HoTFClipRecipe?

    var isClipJob: Bool { recipeKind == .clip }

    init(
        id: String, clientId: String?, clientSlug: String?, name: String?, status: String,
        recipe: HoTFRecipe, mediaManifest: HoTFMediaManifestMap?, dialed: HoTFRecipe?,
        outputUrl: String?, notionRenderPageId: String?, claimedBy: String?, createdAt: String?,
        recipeKind: HoTFRecipeKind = .modeC, clipRecipe: HoTFClipRecipe? = nil, dialedClipRecipe: HoTFClipRecipe? = nil
    ) {
        self.id = id
        self.clientId = clientId
        self.clientSlug = clientSlug
        self.name = name
        self.status = status
        self.recipe = recipe
        self.mediaManifest = mediaManifest
        self.dialed = dialed
        self.outputUrl = outputUrl
        self.notionRenderPageId = notionRenderPageId
        self.claimedBy = claimedBy
        self.createdAt = createdAt
        self.recipeKind = recipeKind
        self.clipRecipe = clipRecipe
        self.dialedClipRecipe = dialedClipRecipe
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case clientId = "client_id"
        case clientSlug = "client_slug"
        case name
        case status
        case recipe
        case mediaManifest = "media_manifest"
        case dialed
        case outputUrl = "output_url"
        case notionRenderPageId = "notion_render_page_id"
        case claimedBy = "claimed_by"
        case createdAt = "created_at"
    }

    /// The Mode C recipe to dial: the human-dialed one if present, else the original.
    var workingRecipe: HoTFRecipe { dialed ?? recipe }

    /// The Mode D clip recipe to render: dialed clip if present, else the original.
    var workingClipRecipe: HoTFClipRecipe? { dialedClipRecipe ?? clipRecipe }
}

extension HoTFEditorJob: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawRecipe = (try? c.decode(RawJSON.self, forKey: .recipe))?.value
        let rawDialed = (try? c.decode(RawJSON.self, forKey: .dialed))?.value

        let clip = HoTFClipRecipe.from(rawRecipe: rawRecipe)
        let dialedClip = HoTFClipRecipe.from(rawRecipe: rawDialed)

        // Mode C decodes the typed recipe; a clip job keeps the placeholder so the
        // non-optional field stays valid and Mode C call sites still compile.
        let recipe: HoTFRecipe = clip != nil
            ? .placeholder
            : try c.decode(HoTFRecipe.self, forKey: .recipe)
        let dialed: HoTFRecipe? = (clip != nil || dialedClip != nil)
            ? nil
            : (try? c.decode(HoTFRecipe.self, forKey: .dialed))

        self.init(
            id: try c.decode(String.self, forKey: .id),
            clientId: try? c.decode(String.self, forKey: .clientId),
            clientSlug: try? c.decode(String.self, forKey: .clientSlug),
            name: try? c.decode(String.self, forKey: .name),
            status: (try? c.decode(String.self, forKey: .status)) ?? "open",
            recipe: recipe,
            mediaManifest: try? c.decode(HoTFMediaManifestMap.self, forKey: .mediaManifest),
            dialed: dialed,
            outputUrl: try? c.decode(String.self, forKey: .outputUrl),
            notionRenderPageId: try? c.decode(String.self, forKey: .notionRenderPageId),
            claimedBy: try? c.decode(String.self, forKey: .claimedBy),
            createdAt: try? c.decode(String.self, forKey: .createdAt),
            recipeKind: clip != nil ? .clip : .modeC,
            clipRecipe: clip,
            dialedClipRecipe: dialedClip
        )
    }
}

/// One row of `templates` — the format library the editor browses for manual
/// edits. Carries a full recipe so it opens straight into a timeline.
struct HoTFTemplate: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var clientSlug: String?
    var formatKind: String?
    var segmentCount: Int?
    var durationSec: Double?
    var recipe: HoTFRecipe
    var mediaManifest: HoTFMediaManifestMap?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case clientSlug = "client_slug"
        case formatKind = "format_kind"
        case segmentCount = "segment_count"
        case durationSec = "duration_sec"
        case recipe
        case mediaManifest = "media_manifest"
    }
}

// MARK: - Workbench mirror (Reeve Notion DBs, synced into Supabase)

/// One row of `wb_format_templates` — the Reeve "Format Templates" catalog.
struct HoTFCatalogTemplate: Codable, Equatable, Identifiable {
    var notionId: String
    var name: String?
    var status: String?
    var props: Props?

    var id: String { notionId }

    struct Props: Codable, Equatable {
        var durationSec: Double?
        var segmentCount: Double?
        var vibeTags: [String]?
        var sourceUrl: String?
        var templateJsonPath: String?

        enum CodingKeys: String, CodingKey {
            case durationSec = "Duration Sec"
            case segmentCount = "Segment Count"
            case vibeTags = "Vibe Tags"
            case sourceUrl = "Source URL"
            case templateJsonPath = "Template JSON Path"
        }
    }

    enum CodingKeys: String, CodingKey {
        case notionId = "notion_id"
        case name, status, props
    }
}

/// One row of `wb_projects` — an editable instance (a Reeve variation). Carries
/// the full recipe so it opens straight into a timeline; Send for Render pushes
/// it onto the queue (editor_jobs).
struct HoTFProject: Codable, Equatable, Identifiable {
    var id: String
    var name: String?
    var clientSlug: String?
    var status: String?
    var templateName: String?
    var segmentCount: Int?
    var recipe: HoTFRecipe
    var mediaManifest: HoTFMediaManifestMap?
    var thumbnailUrl: String?
    var outputUrl: String?

    /// Synthesize the editor-job shape the importer/dial helpers expect.
    func asEditorJob() -> HoTFEditorJob {
        HoTFEditorJob(
            id: id, clientId: nil, clientSlug: clientSlug, name: name,
            status: status ?? "open", recipe: recipe, mediaManifest: mediaManifest,
            dialed: nil, outputUrl: outputUrl, notionRenderPageId: nil,
            claimedBy: nil, createdAt: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, recipe
        case clientSlug = "client_slug"
        case templateName = "template_name"
        case segmentCount = "segment_count"
        case mediaManifest = "media_manifest"
        case thumbnailUrl = "thumbnail_url"
        case outputUrl = "output_url"
    }
}

/// One row of `editor_templates` — a template saved/refined from the editor.
struct HoTFSavedTemplate: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var sourceProjectId: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case sourceProjectId = "source_project_id"
    }
}

/// One row of `wb_render_queue` — the Reeve Notion Render Queue (source of truth).
struct HoTFQueueItem: Codable, Equatable, Identifiable {
    var notionId: String
    var name: String?
    var status: String?
    var lastEdited: String?

    var id: String { notionId }

    enum CodingKeys: String, CodingKey {
        case notionId = "notion_id"
        case name, status
        case lastEdited = "last_edited"
    }
}

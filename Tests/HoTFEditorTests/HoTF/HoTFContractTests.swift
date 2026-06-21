import Foundation
import Testing
@testable import HoTFEditor

@Suite("HoTF mailbox contract")
@MainActor
struct HoTFContractTests {

    /// A realistic `editor_jobs` row as the Trial Reel Engine writes it: a POV
    /// header recipe — color header segment + two b-roll slots, a hook overlay,
    /// and a voiceover audio slot.
    static let rowJSON = """
    {
      "id": "11111111-2222-3333-4444-555555555555",
      "client_slug": "blake",
      "name": "POV hook test",
      "status": "ready",
      "media_manifest": {
        "asset-a": { "proxyUrl": "https://example.com/a-proxy.mp4", "fullResUrl": "https://example.com/a.mp4" },
        "asset-b": { "proxyUrl": "https://example.com/b-proxy.mp4", "fullResUrl": "https://example.com/b.mp4" },
        "vo-1": { "proxyUrl": "https://example.com/vo-proxy.mp3", "fullResUrl": "https://example.com/vo.mp3" }
      },
      "notion_render_page_id": "notion-123",
      "recipe": {
        "hookText": "I quit my job at 18",
        "resolution": {
          "brollSlots": { "slot_1": "https://example.com/a.mp4", "slot_2": "https://example.com/b.mp4" },
          "audioSlots": { "vo": "https://example.com/vo.mp3" },
          "literals": { "hook": "I quit my job at 18" },
          "assetRefs": {
            "slot_1": { "id": "asset-a", "filename": "a.mp4", "type": "video" },
            "slot_2": { "id": "asset-b", "filename": "b.mp4", "type": "video" },
            "vo": { "id": "vo-1", "filename": "vo.mp3", "type": "audio" }
          }
        },
        "template": {
          "id": "FMT-1", "version": 1, "name": "pov", "formatKind": "pov-header",
          "sourceUrl": "", "durationSec": 6,
          "canvas": { "width": 1080, "height": 1920, "fps": 30 },
          "requiredAssetTags": [], "vibeTags": [],
          "pacing": { "avgCutSec": 2, "style": "medium" },
          "editBrief": { "version": 1, "filled": true, "styleSummary": "ignored unknown key" },
          "audio": { "primary": { "kind": "voiceover_slot", "slotId": "vo" } },
          "segments": [
            { "id": "seg_01", "t0": 0, "t1": 2, "media": { "kind": "color", "hex": "#060305" },
              "text": { "copy": "{{hook}}", "position": "top-center", "appearAtFrame": 0 } },
            { "id": "seg_02", "t0": 0, "t1": 2.5, "startFromFrames": 15, "speed": 1,
              "media": { "kind": "broll_slot", "slotId": "slot_1", "tagQuery": ["authority"] },
              "framing": { "fit": "cover", "objectPosition": "50% 40%" } },
            { "id": "seg_03", "t0": 0, "t1": 1.5,
              "media": { "kind": "broll_slot", "slotId": "slot_2", "tagQuery": ["proof"] } }
          ]
        }
      }
    }
    """

    func decodedJob() throws -> HoTFEditorJob {
        try JSONDecoder().decode(HoTFEditorJob.self, from: Data(Self.rowJSON.utf8))
    }

    @Test func decodesRowWithUnions() throws {
        let job = try decodedJob()
        #expect(job.status == "ready")
        #expect(job.clientSlug == "blake")
        #expect(job.notionRenderPageId == "notion-123")
        #expect(job.recipe.template.segments.count == 3)
        #expect(job.mediaManifest?["asset-a"]?.proxyUrl == "https://example.com/a-proxy.mp4")
        if case .color(let hex) = job.recipe.template.segments[0].media {
            #expect(hex == "#060305")
        } else { Issue.record("seg_01 should be color") }
        #expect(job.recipe.template.segments[1].media.slotId == "slot_1")
        #expect(job.recipe.template.audio.primary.slotId == "vo")
    }

    @Test func buildsTimelineWithVideoTextAudioTracks() throws {
        let job = try decodedJob()
        let timeline = HoTFJobImporter.buildTimeline(recipe: job.recipe)
        #expect(timeline.fps == 30)
        #expect(timeline.width == 1080 && timeline.height == 1920)

        let video = timeline.tracks.first { $0.type == .video }
        let text = timeline.tracks.first { $0.type == .text }
        let audio = timeline.tracks.first { $0.type == .audio }

        // Two non-color segments -> two video clips; placed sequentially.
        #expect(video?.clips.count == 2)
        #expect(video?.clips.first?.mediaRef == "asset-a")
        #expect(video?.clips.first?.trimStartFrame == 15)
        // seg_01 (color, 2s=60f) then seg_02 starts at frame 60.
        #expect(video?.clips.first?.startFrame == 60)

        // One hook overlay at the very start.
        #expect(text?.clips.count == 1)
        #expect(text?.clips.first?.textContent == "I quit my job at 18")
        #expect(text?.clips.first?.startFrame == 0)

        // One audio clip spanning the whole timeline (2 + 2.5 + 1.5 = 6s = 180f).
        #expect(audio?.clips.count == 1)
        #expect(audio?.clips.first?.mediaRef == "vo-1")
        #expect(timeline.totalFrames == 180)
    }

    @Test func dialedRecipeReEncodesToValidJSON() throws {
        let job = try decodedJob()
        // Re-encoding the working recipe must stay decodable (Codable round-trip
        // through the discriminated unions Reeve will read back).
        let data = try JSONEncoder().encode(job.workingRecipe)
        let again = try JSONDecoder().decode(HoTFRecipe.self, from: data)
        #expect(again.template.segments.count == 3)
        #expect(again.hookText == "I quit my job at 18")
        if case .voiceoverSlot(let slotId) = again.template.audio.primary {
            #expect(slotId == "vo")
        } else { Issue.record("audio primary should be voiceover_slot") }
    }

    @Test func modeCJobReportsModeCKind() throws {
        let job = try decodedJob()
        #expect(job.recipeKind == .modeC)
        #expect(job.isClipJob == false)
        #expect(job.clipRecipe == nil)
        #expect(job.workingClipRecipe == nil)
    }

    // MARK: - Mode D clip jobs

    /// A `kind:"clip"` row carrying a full native editor `Timeline` (the same JSON
    /// the `.hotf` package stores). Two video clips + one text clip + an audio
    /// clip, with a keyframe track to prove rich edits survive losslessly.
    static func clipRowJSON(timelineJSON: String) -> String {
        """
        {
          "id": "aaaa1111-bbbb-2222-cccc-333344445555",
          "client_slug": "blake",
          "name": "Clip job test",
          "status": "ready",
          "media_manifest": {
            "asset-a": { "proxyUrl": "https://example.com/a-proxy.mp4", "fullResUrl": "https://example.com/a.mp4" },
            "asset-b": { "proxyUrl": "https://example.com/b-proxy.mp4", "fullResUrl": "https://example.com/b.mp4" },
            "vo-1": { "proxyUrl": "https://example.com/vo-proxy.mp3", "fullResUrl": "https://example.com/vo.mp3" }
          },
          "recipe": {
            "kind": "clip",
            "fps": 30,
            "width": 1080,
            "height": 1920,
            "timeline": \(timelineJSON)
          }
        }
        """
    }

    /// Build a real editor timeline, serialize it exactly as the project package
    /// would, and embed it as the clip recipe's `timeline`.
    static func sampleTimeline() -> Timeline {
        var timeline = Timeline()
        timeline.fps = 30
        timeline.width = 1080
        timeline.height = 1920
        timeline.settingsConfigured = true

        var a = Clip(mediaRef: "asset-a", startFrame: 0, durationFrames: 60)
        a.mediaType = .video
        a.trimStartFrame = 15
        a.speed = 1.5
        a.upsertKeyframe(in: \.scaleTrack, frame: 0, value: AnimPair(a: 1.0, b: 1.0))
        a.upsertKeyframe(in: \.scaleTrack, frame: 30, value: AnimPair(a: 1.2, b: 1.2))

        var b = Clip(mediaRef: "asset-b", startFrame: 60, durationFrames: 45)
        b.mediaType = .video

        var text = Clip(mediaRef: "", startFrame: 0, durationFrames: 40)
        text.mediaType = .text
        text.sourceClipType = .text
        text.textContent = "I quit my job at 18"
        text.textStyle = TextStyle()

        var audio = Clip(mediaRef: "vo-1", startFrame: 0, durationFrames: 105)
        audio.mediaType = .audio

        timeline.tracks = [
            Track(type: .video, clips: [a, b]),
            Track(type: .text, clips: [text]),
            Track(type: .audio, clips: [audio]),
        ]
        return timeline
    }

    @Test func decodesClipJobWithNativeTimeline() throws {
        let timeline = Self.sampleTimeline()
        let timelineJSON = String(decoding: try JSONEncoder().encode(timeline), as: UTF8.self)
        let job = try JSONDecoder().decode(
            HoTFEditorJob.self, from: Data(Self.clipRowJSON(timelineJSON: timelineJSON).utf8)
        )

        #expect(job.recipeKind == .clip)
        #expect(job.isClipJob)
        #expect(job.status == "ready")
        #expect(job.mediaManifest?["asset-a"]?.proxyUrl == "https://example.com/a-proxy.mp4")

        let clip = try #require(job.workingClipRecipe)
        #expect(clip.fps == 30)
        #expect(clip.width == 1080)
        #expect(clip.height == 1920)

        // The carried timeline decodes straight back into the native model.
        let decoded = try clip.decodedTimeline()
        #expect(decoded == timeline)
    }

    @Test func clipTimelineRoundTripsLosslessly() throws {
        // open (decode) → edit-in-place → dialed (re-encode) must preserve the
        // exact native timeline, including keyframe tracks and trims.
        let original = Self.sampleTimeline()
        let timelineJSON = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        let job = try JSONDecoder().decode(
            HoTFEditorJob.self, from: Data(Self.clipRowJSON(timelineJSON: timelineJSON).utf8)
        )
        let clip = try #require(job.clipRecipe)
        let reopened = try clip.decodedTimeline()
        #expect(reopened == original)

        // Encode the dialed clip recipe object and decode it back as a clip job.
        let dialed = HoTFClipRecipe(
            timelineData: try JSONEncoder().encode(reopened),
            fps: reopened.fps, width: reopened.width, height: reopened.height
        )
        let dialedObject = try dialed.encodedRecipeObject()
        #expect(dialedObject["kind"] as? String == "clip")
        let row: [String: Any] = [
            "id": "x", "status": "approved", "dialed": dialedObject,
            "recipe": dialedObject,
        ]
        let rowData = try JSONSerialization.data(withJSONObject: row)
        let again = try JSONDecoder().decode(HoTFEditorJob.self, from: rowData)
        let againClip = try #require(again.workingClipRecipe)
        #expect(try againClip.decodedTimeline() == original)
    }
}

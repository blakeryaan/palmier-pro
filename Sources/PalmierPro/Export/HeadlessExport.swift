import AVFoundation
import AppKit

/// Headless render: bake a `.palmier` project to a video file with no window,
/// reusing the GUI's exact compositor (`ExportEngine`). This is the render-back
/// for agent-produced edits — the agent box opens an edited project and exports
/// it here, so zoom keyframes, word captions, and text bubbles all bake.
///
/// CLI:
///   PalmierPro --export <project.palmier> [--out file.mp4]
///              [--codec h264|h265|prores] [--resolution 720p|1080p|4K]
enum HeadlessExport {

    struct Request {
        var projectURL: URL
        var outputURL: URL
        var format: ExportFormat
        var resolution: ExportResolution
    }

    enum ParseError: LocalizedError {
        case missingProject
        case unknownCodec(String)
        case unknownResolution(String)

        var errorDescription: String? {
            switch self {
            case .missingProject: "--export requires a path to a .palmier project"
            case let .unknownCodec(v): "unknown --codec '\(v)' (h264|h265|prores)"
            case let .unknownResolution(v): "unknown --resolution '\(v)' (720p|1080p|4K)"
            }
        }
    }

    /// Returns a parsed request iff `--export` is present, else nil (GUI launch).
    /// Throws on `--export` with bad/missing arguments so the CLI fails loudly.
    static func parse(_ args: [String]) -> Result<Request, Error>? {
        guard args.contains("--export") else { return nil }
        return Result { try buildRequest(args) }
    }

    private static func buildRequest(_ args: [String]) throws -> Request {
        func value(for flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        guard let projectPath = value(for: "--export") else { throw ParseError.missingProject }
        let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL

        let format: ExportFormat
        switch (value(for: "--codec") ?? "h264").lowercased() {
        case "h264": format = .h264
        case "h265", "hevc": format = .h265
        case "prores": format = .prores
        case let other: throw ParseError.unknownCodec(other)
        }

        let resolution: ExportResolution
        switch (value(for: "--resolution") ?? "1080p").lowercased() {
        case "720p", "720": resolution = .r720p
        case "1080p", "1080": resolution = .r1080p
        case "4k", "2160", "2160p": resolution = .r4k
        case let other: throw ParseError.unknownResolution(other)
        }

        let outputURL: URL
        if let out = value(for: "--out") {
            outputURL = URL(fileURLWithPath: out).standardizedFileURL
        } else {
            let base = projectURL.deletingPathExtension().lastPathComponent
            outputURL = projectURL.deletingLastPathComponent()
                .appendingPathComponent("\(base).\(format.fileExtension)")
        }

        return Request(projectURL: projectURL, outputURL: outputURL, format: format, resolution: resolution)
    }

    @MainActor
    static func run(_ req: Request) async throws {
        let (timeline, manifest) = try loadProject(req.projectURL)
        let projectURL = req.projectURL
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { projectURL })

        let session = try await ExportEngine.makeSession(
            timeline: timeline, resolver: resolver, format: req.format, resolution: req.resolution
        )
        guard let fileType = req.format.utType else { throw ExportError.invalidFormat }

        try? FileManager.default.removeItem(at: req.outputURL)
        try await session.export(to: req.outputURL, as: fileType)
    }

    /// Decode `Timeline` + `MediaManifest` straight from the `.palmier` package
    /// dir — same files `VideoProject.read` reads, without the NSDocument/GUI path.
    static func loadProject(_ url: URL) throws -> (Timeline, MediaManifest) {
        let timelineData = try Data(contentsOf: url.appendingPathComponent(Project.timelineFilename))
        let timeline = try JSONDecoder().decode(Timeline.self, from: timelineData)

        var manifest = MediaManifest()
        let manifestURL = url.appendingPathComponent(Project.manifestFilename)
        if let manifestData = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode(MediaManifest.self, from: manifestData) {
            manifest = decoded
        }
        return (timeline, manifest)
    }
}

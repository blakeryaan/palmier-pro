import AVFoundation
import AppKit

/// Shared compositing core for video export. Both the GUI (`ExportService`) and
/// the headless CLI (`HeadlessExport`) build their `AVAssetExportSession` here so
/// what the editor previews is exactly what the agent box bakes — one renderer,
/// no drift. @MainActor because text baking (`TextLayerController`) typesets with
/// AppKit on the main actor.
enum ExportEngine {

    @MainActor
    static func makeSession(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution
    ) async throws -> AVAssetExportSession {
        let renderSize = resolution.renderSize(for: CGSize(width: timeline.width, height: timeline.height))

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { resolver.resolveURL(for: $0) },
            renderSize: renderSize
        )

        guard let session = AVAssetExportSession(
            asset: result.composition,
            presetName: presetName(format: format, resolution: resolution)
        ) else {
            throw ExportError.unsupportedPreset
        }
        session.audioMix = result.audioMix

        // Bake text clips (captions, hooks, bubbles) into the export.
        let (parent, videoLayer) = TextLayerController.buildForExport(
            timeline: timeline,
            fps: timeline.fps,
            renderSize: renderSize
        )
        let mutableVC = result.videoComposition.mutableCopy() as! AVMutableVideoComposition
        mutableVC.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parent
        )
        session.videoComposition = mutableVC
        return session
    }

    static func presetName(format: ExportFormat, resolution: ExportResolution) -> String {
        switch format {
        case .h264:
            switch resolution {
            case .r720p: AVAssetExportPreset1280x720
            case .r1080p: AVAssetExportPreset1920x1080
            case .r4k: AVAssetExportPreset3840x2160
            }
        case .h265:
            switch resolution {
            case .r720p: AVAssetExportPresetHEVC1920x1080
            case .r1080p: AVAssetExportPresetHEVC1920x1080
            case .r4k: AVAssetExportPresetHEVC3840x2160
            }
        case .prores:
            AVAssetExportPresetAppleProRes422LPCM
        case .xml:
            AVAssetExportPresetPassthrough // unreachable — XML never reaches here
        }
    }
}

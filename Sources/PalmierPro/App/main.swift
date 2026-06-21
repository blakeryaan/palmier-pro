import AppKit

Log.bootstrap()
BundledFonts.register()

let app = NSApplication.shared

// Headless render path: `PalmierPro --export <project.palmier> ...` bakes a
// project to video with no window and exits. Shares the GUI's exact compositor.
if let parsed = HeadlessExport.parse(CommandLine.arguments) {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        switch parsed {
        case let .success(request):
            do {
                try await HeadlessExport.run(request)
                FileHandle.standardError.write(Data("export ok → \(request.outputURL.path)\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("export failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        case let .failure(error):
            FileHandle.standardError.write(Data("export error: \(error.localizedDescription)\n".utf8))
            exit(64) // EX_USAGE
        }
    }
    app.run()
}

Telemetry.start()
AccountService.shared.configure()
ModelCatalog.shared.configure()

// Shorten the default tooltip delay from 2s to 0.01s.
UserDefaults.standard.set(10, forKey: "NSInitialToolTipDelay")

let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenuBuilder.buildMenu()
app.run()

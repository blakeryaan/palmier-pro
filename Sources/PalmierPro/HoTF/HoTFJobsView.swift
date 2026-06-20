import AppKit
import SwiftUI

/// Maps an opened job to its editor document so "Approve & Send" can read the
/// dialed timeline. Weak so closing the project doesn't leak it.
@MainActor
final class HoTFOpenJobs {
    static let shared = HoTFOpenJobs()
    private final class WeakDoc { weak var value: VideoProject?; init(_ v: VideoProject) { value = v } }
    private var docs: [String: WeakDoc] = [:]

    func register(_ jobId: String, doc: VideoProject) { docs[jobId] = WeakDoc(doc) }
    func doc(for jobId: String) -> VideoProject? { docs[jobId]?.value }
}

struct HoTFJobsView: View {
    @State private var mailbox = HoTFMailbox.shared
    @State private var portalURL = HoTFConfig.portalBaseURL
    @State private var supabaseURL = HoTFConfig.supabaseURL
    @State private var serviceKey = HoTFConfig.supabaseServiceKey
    @State private var accessToken = HoTFConfig.accessToken
    @State private var busyJobId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header
            if mailbox.isConnected && mailbox.isTeam {
                connectedBar
                Divider().opacity(AppTheme.Opacity.muted)
                jobsList
            } else {
                connectForm
            }
            if let error = mailbox.lastError {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(minWidth: 520, minHeight: 460, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            Text("HoTF Jobs")
                .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer()
            if mailbox.isWorking { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Connect

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Connect to the HoTF mailbox. Paste your HoTF access token and the portal Supabase service key.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)

            field("Portal URL", text: $portalURL) { HoTFConfig.portalBaseURL = $0 }
            field("Supabase URL", text: $supabaseURL) { HoTFConfig.supabaseURL = $0 }
            secureField("Supabase service key", text: $serviceKey) { HoTFConfig.supabaseServiceKey = $0 }
            secureField("HoTF access token", text: $accessToken) { HoTFConfig.accessToken = $0 }

            Button("Connect") {
                HoTFConfig.portalBaseURL = portalURL
                HoTFConfig.supabaseURL = supabaseURL
                HoTFConfig.supabaseServiceKey = serviceKey
                HoTFConfig.accessToken = accessToken
                Task { await mailbox.connect() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(mailbox.isWorking)
        }
    }

    private var connectedBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(mailbox.account?.email ?? "")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text("TEAM")
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer()
            Button("Refresh") { Task { await mailbox.refresh() } }
                .buttonStyle(.bordered)
            Button("Disconnect") { mailbox.disconnect() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Jobs

    private var jobsList: some View {
        Group {
            if mailbox.jobs.isEmpty {
                Text("No jobs waiting. Reeve will push Mode C recipes here for a human pass.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.sm)
            } else {
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(mailbox.jobs) { job in
                            jobRow(job)
                        }
                    }
                }
            }
        }
    }

    private func jobRow(_ job: HoTFEditorJob) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name ?? job.recipe.hookText)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text("\(job.clientSlug ?? "—") · \(job.status)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            if busyJobId == job.id {
                ProgressView().controlSize(.small)
            } else {
                Button(job.status == "ready" ? "Open in Editor" : "Open") {
                    open(job)
                }
                .buttonStyle(.borderedProminent)

                if job.status == "open" {
                    Button("Approve & Send") { approve(job) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
    }

    private func open(_ job: HoTFEditorJob) {
        busyJobId = job.id
        Task {
            defer { busyJobId = nil }
            do {
                var target = job
                if job.status == "ready", let claimed = try await mailbox.claim(job) {
                    target = claimed
                }
                try await HoTFJobImporter.open(target)
                if let doc = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject }).last {
                    HoTFOpenJobs.shared.register(target.id, doc: doc)
                }
                await mailbox.refresh()
            } catch {
                mailbox.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func approve(_ job: HoTFEditorJob) {
        guard let doc = HoTFOpenJobs.shared.doc(for: job.id) else {
            mailbox.lastError = "Open the job in the editor first, then approve."
            return
        }
        busyJobId = job.id
        Task {
            defer { busyJobId = nil }
            do {
                let dialed = HoTFJobImporter.dialedRecipe(from: doc.editorViewModel, job: job)
                try await mailbox.saveDialed(job, dialed: dialed)
                await mailbox.refresh()
            } catch {
                mailbox.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Field helpers

    private func field(_ label: String, text: Binding<String>, onCommit: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text.wrappedValue) { _, value in onCommit(value) }
        }
    }

    private func secureField(_ label: String, text: Binding<String>, onCommit: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            SecureField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text.wrappedValue) { _, value in onCommit(value) }
        }
    }
}

@MainActor
final class HoTFJobsWindowController: NSWindowController {
    static let shared = HoTFJobsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: HoTFJobsView().tint(AppTheme.Accent.primary))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 600, height: 560))
        window.minSize = NSSize(width: 520, height: 460)
        window.title = "HoTF Jobs"
        window.setFrameAutosaveName("PalmierProHoTFJobs")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(AppTheme.Background.surfaceColor)
        window.titlebarAppearsTransparent = true
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

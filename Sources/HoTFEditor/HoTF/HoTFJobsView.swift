import AppKit
import SwiftUI

/// Maps an opened job to its editor document so "Approve & Send" can read the
/// dialed timeline. Weak so closing the project doesn't leak it.
@MainActor
final class HoTFOpenJobs {
    static let shared = HoTFOpenJobs()
    private final class WeakDoc { weak var value: VideoProject?; init(_ v: VideoProject) { value = v } }
    private var docs: [String: WeakDoc] = [:]
    private var projectsByPath: [String: HoTFProject] = [:]

    func register(_ jobId: String, doc: VideoProject) { docs[jobId] = WeakDoc(doc) }
    func doc(for jobId: String) -> VideoProject? { docs[jobId]?.value }

    /// Track an opened HoTF project so the editor's Export sheet can offer
    /// "Send to Agent Render" for it (keyed by the project document's path).
    func registerProject(_ project: HoTFProject, doc: VideoProject) {
        docs[project.id] = WeakDoc(doc)
        if let path = doc.fileURL?.path { projectsByPath[path] = project }
    }

    func project(forPath path: String?) -> HoTFProject? {
        guard let path else { return nil }
        return projectsByPath[path]
    }
}

struct HoTFJobsView: View {
    /// When embedded in the Home window the account/sign-out live in the sidebar
    /// footer, so this panel drops the standalone-window chrome.
    var embedded = false

    @State private var mailbox = HoTFMailbox.shared
    @State private var email = ""
    @State private var password = ""
    @State private var busyJobId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header
            if mailbox.isConnected && mailbox.isTeam {
                if !embedded {
                    connectedBar
                    Divider().opacity(AppTheme.Opacity.muted)
                }
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
        .padding(embedded ? AppTheme.Spacing.xlXxl : AppTheme.Spacing.xl)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil, alignment: .topLeading)
        .frame(minWidth: embedded ? nil : 520, minHeight: embedded ? nil : 460, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(embedded ? "Jobs" : "HoTF Jobs")
                .font(.system(size: embedded ? AppTheme.FontSize.xl : AppTheme.FontSize.lg, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if mailbox.isWorking { ProgressView().controlSize(.small) }
            Spacer()
            if embedded && mailbox.isConnected && mailbox.isTeam {
                Button("Refresh") { Task { await mailbox.refresh() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Connect

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Sign in with your HoTF account.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)

            field("Email", text: $email) { _ in }
            secureField("Password", text: $password) { _ in }

            Button("Sign in") { signIn() }
                .buttonStyle(.borderedProminent)
                .disabled(mailbox.isWorking || email.isEmpty || password.isEmpty)
        }
    }

    private func signIn() {
        Task {
            await mailbox.signIn(email: email, password: password)
            if mailbox.isConnected { password = "" }
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
            Button("Sign Out") { mailbox.signOut() }
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
                    Button("Send for Render") { approve(job) }
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
                await HoTFJobImporter.persist(doc)
                if job.isClipJob {
                    let dialed = try HoTFJobImporter.dialedClipRecipe(from: doc.editorViewModel)
                    try await mailbox.saveDialedClip(job, dialed: dialed)
                } else {
                    let dialed = HoTFJobImporter.dialedRecipe(from: doc.editorViewModel, job: job)
                    try await mailbox.saveDialed(job, dialed: dialed)
                }
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

// MARK: - Sidebar account footer

/// The signed-in HoTF account, shown at the bottom of the Home sidebar with an
/// easy sign-out. When signed out it's a "Sign in" row that opens the Jobs panel.
struct HoTFAccountFooter: View {
    @State private var mailbox = HoTFMailbox.shared
    var onSignInTap: () -> Void

    var body: some View {
        if let account = mailbox.account {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: AppTheme.IconSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(account.email)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(roleLabel(account))
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer(minLength: 0)
                Button(action: { mailbox.signOut() }) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
                }
                .buttonStyle(.plain)
                .help("Sign out of HoTF")
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
        } else {
            SidebarRowButton(
                label: mailbox.isWorking ? "Signing in…" : "Sign in",
                systemImage: "person.crop.circle",
                action: onSignInTap
            )
        }
    }

    private func roleLabel(_ account: HoTFAccount) -> String {
        if account.isMasterAdmin { return "MASTER ADMIN" }
        if account.isTeam { return "TEAM" }
        return account.activeStatus.uppercased()
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
        window.setFrameAutosaveName("HoTFEditorHoTFJobs")
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

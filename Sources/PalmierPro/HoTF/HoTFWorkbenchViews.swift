import AppKit
import SwiftUI

// MARK: - Sign in

/// Email + password sign-in, shown by any workbench tab when signed out.
struct HoTFSignInView: View {
    @State private var mailbox = HoTFMailbox.shared
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Sign in with your HoTF account.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            Button("Sign in") {
                Task {
                    await mailbox.signIn(email: email, password: password)
                    if mailbox.isConnected { password = "" }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(mailbox.isWorking || email.isEmpty || password.isEmpty)
            if let error = mailbox.lastError {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

// MARK: - Shared chrome

private struct WorkbenchHeader: View {
    let title: String
    var count: Int?
    let isWorking: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if let count { Text("\(count)").font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(AppTheme.Text.tertiaryColor) }
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button("Refresh", action: onRefresh).buttonStyle(.bordered)
        }
    }
}

private struct StatusBadge: View {
    let status: String?
    var body: some View {
        if let status, !status.isEmpty {
            Text(status.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(RoundedRectangle(cornerRadius: AppTheme.Radius.xs).fill(Color.white.opacity(AppTheme.Opacity.subtle)))
        }
    }
}

private struct WorkbenchRowCard<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
        .padding(AppTheme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.md).fill(Color.white.opacity(AppTheme.Opacity.subtle)))
    }
}

// MARK: - Templates (wb_format_templates)

struct HoTFFormatTemplatesView: View {
    @State private var mailbox = HoTFMailbox.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if mailbox.isConnected && mailbox.isTeam {
                WorkbenchHeader(title: "Templates", count: mailbox.formatTemplates.count, isWorking: mailbox.isWorking) {
                    Task { await mailbox.refreshFormatTemplates() }
                }
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        if !mailbox.savedTemplates.isEmpty {
                            sectionLabel("Your templates")
                            ForEach(mailbox.savedTemplates) { t in
                                WorkbenchRowCard(title: t.name, subtitle: "saved in editor") {
                                    StatusBadge(status: "DRAFT")
                                }
                            }
                            sectionLabel("Library")
                        }
                        ForEach(mailbox.formatTemplates) { template in
                            WorkbenchRowCard(title: template.name ?? "Untitled", subtitle: subtitle(template)) {
                                StatusBadge(status: template.status)
                            }
                        }
                        if mailbox.formatTemplates.isEmpty && mailbox.savedTemplates.isEmpty {
                            Text("No templates synced yet.")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                    }
                }
            } else {
                Text("Templates").font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                HoTFSignInView()
            }
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await mailbox.refreshFormatTemplates()
            await mailbox.refreshSavedTemplates()
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer()
        }
        .padding(.top, AppTheme.Spacing.sm)
    }

    private func subtitle(_ t: HoTFCatalogTemplate) -> String {
        var parts: [String] = []
        if let s = t.props?.segmentCount { parts.append("\(Int(s)) segments") }
        if let d = t.props?.durationSec { parts.append(String(format: "%.0fs", d)) }
        if let v = t.props?.vibeTags, !v.isEmpty { parts.append(v.prefix(3).joined(separator: " · ")) }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Projects (wb_projects)

struct HoTFProjectsView: View {
    @State private var mailbox = HoTFMailbox.shared
    @State private var busyId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if mailbox.isConnected && mailbox.isTeam {
                WorkbenchHeader(title: "Projects", count: mailbox.projects.count, isWorking: mailbox.isWorking) {
                    Task { await mailbox.refreshProjects() }
                }
                if mailbox.projects.isEmpty {
                    Text("No projects synced yet.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                } else {
                    ScrollView {
                        VStack(spacing: AppTheme.Spacing.sm) {
                            ForEach(mailbox.projects) { project in
                                WorkbenchRowCard(title: project.name ?? "Untitled", subtitle: subtitle(project)) {
                                    if busyId == project.id {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        HStack(spacing: AppTheme.Spacing.sm) {
                                            Button("Open") { open(project) }
                                                .buttonStyle(.borderedProminent)
                                            Button("Send for Render") { send(project) }
                                                .buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if let error = mailbox.lastError {
                    Text(error).font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Projects").font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                HoTFSignInView()
            }
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await mailbox.refreshProjects() }
    }

    private func subtitle(_ p: HoTFProject) -> String {
        var parts: [String] = []
        if let t = p.templateName { parts.append(t) }
        if let c = p.clientSlug { parts.append(c) }
        if let s = p.segmentCount { parts.append("\(s) segments") }
        if let st = p.status { parts.append(st) }
        return parts.joined(separator: "  ·  ")
    }

    private func open(_ project: HoTFProject) {
        busyId = project.id
        Task {
            defer { busyId = nil }
            do {
                // Reuse the already-downloaded local project if we have one.
                if let url = HoTFProjectStore.localURL(for: project.id),
                   FileManager.default.fileExists(atPath: url.path) {
                    let doc = try await openLocal(url)
                    HoTFOpenJobs.shared.registerProject(project, doc: doc)
                    return
                }
                try await HoTFJobImporter.open(project.asEditorJob())
                if let doc = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject }).last {
                    HoTFOpenJobs.shared.registerProject(project, doc: doc)
                    if let url = doc.fileURL { HoTFProjectStore.remember(project.id, url: url) }
                }
            } catch {
                mailbox.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func openLocal(_ url: URL) async throws -> VideoProject {
        try await withCheckedThrowingContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
                if let project = doc as? VideoProject {
                    continuation.resume(returning: project)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private func send(_ project: HoTFProject) {
        guard let doc = HoTFOpenJobs.shared.doc(for: project.id) else {
            mailbox.lastError = "Open the project first, then Send for Render."
            return
        }
        busyId = project.id
        Task {
            defer { busyId = nil }
            do {
                await HoTFJobImporter.persist(doc)
                let dialed = HoTFJobImporter.dialedRecipe(from: doc.editorViewModel, job: project.asEditorJob())
                try await mailbox.sendProjectForRender(project, dialed: dialed)
                await mailbox.refreshRenderQueue()
            } catch {
                mailbox.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Render Queue (wb_render_queue)

struct HoTFRenderQueueView: View {
    @State private var mailbox = HoTFMailbox.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if mailbox.isConnected && mailbox.isTeam {
                WorkbenchHeader(title: "Render Queue", count: mailbox.renderQueue.count, isWorking: mailbox.isWorking) {
                    Task { await mailbox.refreshRenderQueue() }
                }
                if mailbox.renderQueue.isEmpty {
                    Text("Nothing sent for render yet. Open a project, edit, then Send for Render.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                } else {
                    ScrollView {
                        VStack(spacing: AppTheme.Spacing.sm) {
                            ForEach(mailbox.renderQueue) { job in
                                WorkbenchRowCard(title: job.name ?? "Untitled", subtitle: job.clientSlug) {
                                    HStack(spacing: AppTheme.Spacing.sm) {
                                        if let url = job.outputUrl, let link = URL(string: url) {
                                            Link("Frame.io", destination: link)
                                                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                                        }
                                        StatusBadge(status: job.status)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Render Queue").font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                HoTFSignInView()
            }
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await mailbox.refreshRenderQueue() }
    }
}

import AppKit
import SwiftUI

/// The format-template library — browse templates and start a manual edit.
/// "New Edit" creates an `editor_jobs` row from the template and opens it as a
/// timeline; from there it's an ordinary open job (Send for Render unchanged).
struct HoTFTemplatesView: View {
    @State private var mailbox = HoTFMailbox.shared
    @State private var busyId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header
            if mailbox.isConnected && mailbox.isTeam {
                templatesList
            } else {
                Text("Sign in on the Jobs tab to load the template library.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            if let error = mailbox.lastError {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await mailbox.refreshTemplates() }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text("Templates")
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if mailbox.isWorking { ProgressView().controlSize(.small) }
            Spacer()
            if mailbox.isConnected && mailbox.isTeam {
                Button("Refresh") { Task { await mailbox.refreshTemplates() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var templatesList: some View {
        Group {
            if mailbox.templates.isEmpty {
                Text("No templates yet.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.sm)
            } else {
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(mailbox.templates) { template in
                            templateRow(template)
                        }
                    }
                }
            }
        }
    }

    private func templateRow(_ template: HoTFTemplate) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(subtitle(template))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            if busyId == template.id {
                ProgressView().controlSize(.small)
            } else {
                Button("New Edit") { newEdit(template) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
    }

    private func subtitle(_ template: HoTFTemplate) -> String {
        var parts: [String] = []
        if let slug = template.clientSlug { parts.append(slug) }
        if let segments = template.segmentCount { parts.append("\(segments) segments") }
        if let dur = template.durationSec { parts.append(String(format: "%.0fs", dur)) }
        return parts.joined(separator: " · ")
    }

    private func newEdit(_ template: HoTFTemplate) {
        busyId = template.id
        Task {
            defer { busyId = nil }
            do {
                let job = try await mailbox.startEditFromTemplate(template)
                try await HoTFJobImporter.open(job)
                if let doc = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject }).last {
                    HoTFOpenJobs.shared.register(job.id, doc: doc)
                }
                await mailbox.refresh()
            } catch {
                mailbox.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

import Foundation

enum HoTFError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case let .notConfigured(m): return m
        case let .http(code, body): return "HoTF request failed (\(code)). \(body)"
        case let .decode(m): return "Could not read HoTF response: \(m)"
        }
    }
}

/// Talks to the two HoTF surfaces: the portal identity API and the portal
/// Supabase `editor_jobs` mailbox. Single shared instance drives the HoTF Jobs
/// window. See `docs/REEVE_MAILBOX_CONTRACT.md`.
@MainActor
@Observable
final class HoTFMailbox {
    static let shared = HoTFMailbox()

    var account: HoTFAccount?
    var jobs: [HoTFEditorJob] = []
    var isWorking = false
    var lastError: String?

    private let machineName = Host.current().localizedName ?? "palmier-pro-mac"

    var isConnected: Bool { account != nil }
    var isTeam: Bool { account?.isTeam ?? false }

    private init() {}

    // MARK: - Identity

    /// Resolve the signed-in HoTF account from the portal. Team-gated: a client
    /// "owner" is not team and cannot use the editor mailbox.
    func connect() async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        let token = HoTFConfig.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            lastError = "Paste your HoTF access token first."
            return
        }
        guard var components = URLComponents(string: HoTFConfig.portalBaseURL) else {
            lastError = "Portal URL is invalid."
            return
        }
        components.path = "/api/identity/resolve"
        guard let url = components.url else { lastError = "Portal URL is invalid."; return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let secret = HoTFConfig.identitySecret.trimmingCharacters(in: .whitespaces)
        if !secret.isEmpty { request.setValue(secret, forHTTPHeaderField: "x-identity-secret") }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw HoTFError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            let decoded = try JSONDecoder().decode(IdentityResponse.self, from: data)
            account = decoded.account
            if decoded.account.isTeam {
                await refresh()
            } else {
                lastError = "This account is not on the HoTF team — the editor mailbox is team-only."
            }
        } catch {
            account = nil
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func disconnect() {
        account = nil
        jobs = []
        lastError = nil
    }

    private struct IdentityResponse: Codable {
        var ok: Bool
        var account: HoTFAccount
    }

    // MARK: - Mailbox (editor_jobs)

    /// List jobs awaiting a human pass: `ready` (new) and `open` (already claimed here).
    func refresh() async {
        guard isTeam else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            jobs = try await listJobs(statuses: ["ready", "open"])
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func listJobs(statuses: [String]) async throws -> [HoTFEditorJob] {
        var query = "select=*&order=created_at.asc&limit=50"
        query += "&status=in.(\(statuses.joined(separator: ",")))"
        let data = try await rest("editor_jobs?\(query)", method: "GET")
        do {
            return try JSONDecoder().decode([HoTFEditorJob].self, from: data)
        } catch {
            throw HoTFError.decode(error.localizedDescription)
        }
    }

    /// Move a `ready` job to `open` for this machine. Returns the claimed row, or
    /// nil if another machine won the race.
    func claim(_ job: HoTFEditorJob) async throws -> HoTFEditorJob? {
        let body = try JSONSerialization.data(withJSONObject: ["status": "open", "claimed_by": machineName])
        let data = try await rest(
            "editor_jobs?id=eq.\(job.id)&status=eq.ready",
            method: "PATCH",
            body: body,
            prefer: "return=representation"
        )
        let rows = (try? JSONDecoder().decode([HoTFEditorJob].self, from: data)) ?? []
        return rows.first
    }

    /// Save the human-dialed recipe and mark the job approved (ready to render).
    func saveDialed(_ job: HoTFEditorJob, dialed: HoTFRecipe) async throws {
        let encoder = JSONEncoder()
        let dialedData = try encoder.encode(dialed)
        let dialedObject = try JSONSerialization.jsonObject(with: dialedData)
        let body = try JSONSerialization.data(withJSONObject: [
            "status": "approved",
            "dialed": dialedObject,
        ])
        _ = try await rest("editor_jobs?id=eq.\(job.id)", method: "PATCH", body: body, prefer: "return=minimal")
    }

    // MARK: - REST plumbing

    private func rest(_ path: String, method: String, body: Data? = nil, prefer: String? = nil) async throws -> Data {
        guard HoTFConfig.isConfigured else {
            throw HoTFError.notConfigured("Set the HoTF Supabase URL and service key in the HoTF Jobs window.")
        }
        let base = HoTFConfig.supabaseURL.hasSuffix("/") ? String(HoTFConfig.supabaseURL.dropLast()) : HoTFConfig.supabaseURL
        guard let url = URL(string: "\(base)/rest/v1/\(path)") else {
            throw HoTFError.notConfigured("Invalid Supabase URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let key = HoTFConfig.supabaseServiceKey
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw HoTFError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

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
    var templates: [HoTFTemplate] = []
    var formatTemplates: [HoTFCatalogTemplate] = []
    var savedTemplates: [HoTFSavedTemplate] = []
    var renderQueue: [HoTFEditorJob] = []
    var projects: [HoTFProject] = []
    var isWorking = false
    var lastError: String?

    private let machineName = Host.current().localizedName ?? "palmier-pro-mac"

    var isConnected: Bool { account != nil }
    var isTeam: Bool { account?.isTeam ?? false }

    private init() {}

    // MARK: - Auth (Supabase password grant)

    /// Sign in with a HoTF email + password. Mints access/refresh tokens
    /// (saved to Keychain), then resolves + team-gates the account.
    func signIn(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            lastError = "Enter your HoTF email and password."
            return
        }
        guard HoTFConfig.canSignIn else {
            lastError = "HoTF anon key not set. Add it under Advanced (one time)."
            return
        }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let tokens = try await requestToken(grant: "password", body: ["email": email, "password": password])
            HoTFConfig.accessToken = tokens.accessToken
            HoTFConfig.refreshToken = tokens.refreshToken
            await resolveIdentity()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Launch path: exchange the stored refresh token for a fresh access token,
    /// then resolve the account. Silent no-op when no session is stored.
    func restore() async {
        let refresh = HoTFConfig.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refresh.isEmpty, HoTFConfig.canSignIn else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await refreshSession(refresh: refresh)
            await resolveIdentity()
        } catch {
            // Refresh token expired/revoked — drop it and let the user sign in again.
            HoTFConfig.clearSession()
            account = nil
        }
    }

    func signOut() {
        HoTFConfig.clearSession()
        account = nil
        jobs = []
        lastError = nil
    }

    private struct TokenPair {
        var accessToken: String
        var refreshToken: String
    }

    private struct TokenResponse: Codable {
        var access_token: String
        var refresh_token: String
    }

    /// POST `{SUPABASE_URL}/auth/v1/token?grant_type=<grant>` with the anon key.
    private func requestToken(grant: String, body: [String: String]) async throws -> TokenPair {
        let base = HoTFConfig.supabaseURL.hasSuffix("/") ? String(HoTFConfig.supabaseURL.dropLast()) : HoTFConfig.supabaseURL
        guard let url = URL(string: "\(base)/auth/v1/token?grant_type=\(grant)") else {
            throw HoTFError.notConfigured("Invalid Supabase URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(HoTFConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 400 { throw HoTFError.http(code, "Email or password is incorrect.") }
            throw HoTFError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            return TokenPair(accessToken: decoded.access_token, refreshToken: decoded.refresh_token)
        } catch {
            throw HoTFError.decode(error.localizedDescription)
        }
    }

    /// Refresh the access token and persist the rotated pair.
    private func refreshSession(refresh: String) async throws {
        let tokens = try await requestToken(grant: "refresh_token", body: ["refresh_token": refresh])
        HoTFConfig.accessToken = tokens.accessToken
        HoTFConfig.refreshToken = tokens.refreshToken
    }

    // MARK: - Identity

    /// Resolve the signed-in HoTF account from the portal. Team-gated: a client
    /// "owner" is not team and cannot use the editor mailbox. On a 401 the access
    /// token is refreshed once and the call retried.
    private func resolveIdentity(retryOnUnauthorized: Bool = true) async {
        guard var components = URLComponents(string: HoTFConfig.portalBaseURL) else {
            lastError = "Portal URL is invalid."
            return
        }
        components.path = "/api/identity/resolve"
        guard let url = components.url else { lastError = "Portal URL is invalid."; return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(HoTFConfig.accessToken)", forHTTPHeaderField: "Authorization")
        let secret = HoTFConfig.identitySecret.trimmingCharacters(in: .whitespaces)
        if !secret.isEmpty { request.setValue(secret, forHTTPHeaderField: "x-identity-secret") }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401, retryOnUnauthorized,
               !HoTFConfig.refreshToken.isEmpty,
               (try? await refreshSession(refresh: HoTFConfig.refreshToken)) != nil {
                return await resolveIdentity(retryOnUnauthorized: false)
            }
            guard (200..<300).contains(code) else {
                throw HoTFError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            let decoded = try JSONDecoder().decode(IdentityResponse.self, from: data)
            account = decoded.account
            if decoded.account.isTeam {
                await refresh()
                await refreshProjects()
                await refreshFormatTemplates()
                await refreshSavedTemplates()
                await refreshRenderQueue()
                Task { await prefetchRecentProjects() }
            } else {
                lastError = "This account is not on the HoTF team — the editor mailbox is team-only."
            }
        } catch {
            account = nil
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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

    // MARK: - Projects (editable instances)

    /// Background-download the most recent projects' media into the local cache
    /// so the first Open is instant. Skips any already cached.
    func prefetchRecentProjects(_ count: Int = 3) async {
        for project in projects.prefix(count) {
            if let url = HoTFProjectStore.localURL(for: project.id),
               FileManager.default.fileExists(atPath: url.path) { continue }
            if let url = try? await HoTFJobImporter.prepare(project.asEditorJob()) {
                HoTFProjectStore.remember(project.id, url: url)
            }
        }
    }

    /// Editable projects (mirrored Reeve variations), most-recent first.
    func refreshProjects() async {
        guard isTeam else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await rest("wb_projects?select=*&order=updated_at.desc.nullslast&limit=100", method: "GET")
            projects = Self.decodeLenient(data)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Send a (dialed) project to the render queue: a new `editor_jobs` row,
    /// status `approved` with the edited recipe — exactly what the worker waits on.
    func sendProjectForRender(_ project: HoTFProject, dialed: HoTFRecipe) async throws {
        let recipeObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project.recipe))
        let dialedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dialed))
        var fields: [String: Any] = [
            "name": project.name ?? project.recipe.hookText,
            "status": "approved",
            "recipe": recipeObject,
            "dialed": dialedObject,
        ]
        if let slug = project.clientSlug { fields["client_slug"] = slug }
        if let manifest = project.mediaManifest {
            fields["media_manifest"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
        }
        let body = try JSONSerialization.data(withJSONObject: fields)
        _ = try await rest("editor_jobs", method: "POST", body: body, prefer: "return=minimal")
    }

    // MARK: - Saved templates (human-authored / refined)

    func refreshSavedTemplates() async {
        guard isTeam else { return }
        do {
            let data = try await rest("editor_templates?select=id,name,source_project_id&order=created_at.desc&limit=200", method: "GET")
            savedTemplates = Self.decodeLenient(data)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Save the edited timeline's structure as a reusable Mode C template.
    func saveAsTemplate(name: String, template: HoTFFormatTemplate, sourceProjectId: String?) async throws {
        var template = template
        template.name = name
        let id = "editor-\(Self.slug(name))-\(UUID().uuidString.prefix(6).lowercased())"
        let templateObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template))
        var fields: [String: Any] = ["id": id, "name": name, "template": templateObject]
        if let sourceProjectId { fields["source_project_id"] = sourceProjectId }
        if let email = account?.email { fields["created_by"] = email }
        let body = try JSONSerialization.data(withJSONObject: fields)
        _ = try await rest("editor_templates", method: "POST", body: body, prefer: "return=minimal")
        await refreshSavedTemplates()
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? $0 : "-" }
        return String(String(mapped).split(separator: "-").joined(separator: "-").prefix(40))
    }

    // MARK: - Workbench mirror (Reeve Notion DBs)

    /// The Reeve "Format Templates" catalog, mirrored into Supabase.
    func refreshFormatTemplates() async {
        guard isTeam else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await rest("wb_format_templates?select=notion_id,name,status,props&order=name.asc", method: "GET")
            formatTemplates = Self.decodeLenient(data)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The Mode C render queue — the editor's own `editor_jobs`, most-recent
    /// first. Pure Mode C (the editor only sends Mode C), and carries live
    /// status + the Frame.io `output_url` once the agent box renders.
    func refreshRenderQueue() async {
        guard isTeam else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await rest("editor_jobs?select=*&order=updated_at.desc&limit=100", method: "GET")
            renderQueue = Self.decodeLenient(data)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Templates (the format library)

    /// List the format-template library for the Templates tab.
    func refreshTemplates() async {
        guard isTeam else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await rest("templates?select=*&order=name.asc", method: "GET")
            templates = Self.decodeLenient(data)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Start a manual edit from a template: insert a fresh `editor_jobs` row
    /// (status `open`, claimed here) seeded with the template's recipe. It then
    /// behaves exactly like an opened job — Send for Render works unchanged.
    func startEditFromTemplate(_ template: HoTFTemplate) async throws -> HoTFEditorJob {
        let recipeObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template.recipe))
        var fields: [String: Any] = [
            "name": template.name,
            "status": "open",
            "claimed_by": machineName,
            "recipe": recipeObject,
        ]
        if let slug = template.clientSlug { fields["client_slug"] = slug }
        if let manifest = template.mediaManifest {
            fields["media_manifest"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
        }
        let body = try JSONSerialization.data(withJSONObject: fields)
        let data = try await rest("editor_jobs", method: "POST", body: body, prefer: "return=representation")
        guard let job = (try? JSONDecoder().decode([HoTFEditorJob].self, from: data))?.first else {
            throw HoTFError.decode("Creating the job returned no row.")
        }
        return job
    }

    private func listJobs(statuses: [String]) async throws -> [HoTFEditorJob] {
        var query = "select=*&order=created_at.asc&limit=50"
        query += "&status=in.(\(statuses.joined(separator: ",")))"
        let data = try await rest("editor_jobs?\(query)", method: "GET")
        return Self.decodeLenient(data)
    }

    /// Decode a PostgREST array element-by-element so one row that fails to map
    /// (an unexpected template/segment shape) doesn't blank the whole list.
    static func decodeLenient<T: Decodable>(_ data: Data) -> [T] {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        let decoder = JSONDecoder()
        var out: [T] = []
        var skipped = 0
        for element in raw {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let decoded = try? decoder.decode(T.self, from: elementData) else {
                skipped += 1
                continue
            }
            out.append(decoded)
        }
        if skipped > 0 {
            Log.project.error("HoTF \(T.self): skipped \(skipped)/\(raw.count) undecodable row(s)")
        }
        return out
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

    /// URLSession with one retry on transient failures (a dropped keep-alive
    /// surfaces as `.networkConnectionLost` even though the network is fine).
    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let transient: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet]
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where transient.contains(error.code) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return try await URLSession.shared.data(for: request)
        }
    }

    /// Mailbox REST on the signed-in user's token. The portal Supabase RLS
    /// (`is_hotf_team()`) authorises team members — no service key on the client.
    /// A 401 triggers one refresh + retry.
    private func rest(_ path: String, method: String, body: Data? = nil, prefer: String? = nil, retryOnUnauthorized: Bool = true) async throws -> Data {
        guard HoTFConfig.isConfigured else {
            throw HoTFError.notConfigured("Sign in to the HoTF mailbox first.")
        }
        let base = HoTFConfig.supabaseURL.hasSuffix("/") ? String(HoTFConfig.supabaseURL.dropLast()) : HoTFConfig.supabaseURL
        guard let url = URL(string: "\(base)/rest/v1/\(path)") else {
            throw HoTFError.notConfigured("Invalid Supabase URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(HoTFConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(HoTFConfig.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = body

        let (data, response) = try await Self.send(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.project.info("HoTF REST \(method) \(path) → \(code) (\(data.count)b, token=\(HoTFConfig.accessToken.isEmpty ? "EMPTY" : "set"))")
        if code == 401, retryOnUnauthorized,
           !HoTFConfig.refreshToken.isEmpty,
           (try? await refreshSession(refresh: HoTFConfig.refreshToken)) != nil {
            return try await rest(path, method: method, body: body, prefer: prefer, retryOnUnauthorized: false)
        }
        guard (200..<300).contains(code) else {
            throw HoTFError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

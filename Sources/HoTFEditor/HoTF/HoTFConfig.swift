import Foundation

/// Connection settings for the HoTF mailbox + identity. Stored in UserDefaults
/// and editable from the HoTF Jobs window. The editor talks to two HoTF
/// surfaces: the portal identity API (Bearer, the signed-in user's Supabase
/// access token) and the portal Supabase project's `editor_jobs` table
/// (service key — this is an internal team tool running on a trusted Mac).
enum HoTFConfig {
    private static let d = UserDefaults.standard

    private enum Key {
        static let portalBaseURL = "hotf.portalBaseURL"
        static let supabaseURL = "hotf.supabaseURL"
        static let supabaseAnonKey = "hotf.supabaseAnonKey"
        static let identitySecret = "hotf.identitySecret"
        static let accessToken = "hotf.accessToken"
        static let refreshToken = "hotf.refreshToken"
    }

    static let defaultPortalBaseURL = "https://clients.thehotf.com"
    static let defaultSupabaseURL = "https://xxtuqjtwspjcbwvqdfof.supabase.co"

    /// Portal anon (publishable) key. Public by design — safe to embed/ship.
    /// Mirrors the portal's `NEXT_PUBLIC_SUPABASE_ANON_KEY`. An Advanced field
    /// can still override it at runtime.
    static let defaultSupabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inh4dHVxanR3c3BqY2J3dnFkZm9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYzNzU0MjQsImV4cCI6MjA5MTk1MTQyNH0.6h5t5QSNA43-hbJGRdW94nntSlfZHDqa-aSHOwte1yQ"

    static var portalBaseURL: String {
        get { nonEmpty(d.string(forKey: Key.portalBaseURL)) ?? defaultPortalBaseURL }
        set { d.set(newValue, forKey: Key.portalBaseURL) }
    }

    static var supabaseURL: String {
        get { nonEmpty(d.string(forKey: Key.supabaseURL)) ?? defaultSupabaseURL }
        set { d.set(newValue, forKey: Key.supabaseURL) }
    }

    static var supabaseAnonKey: String {
        get { nonEmpty(d.string(forKey: Key.supabaseAnonKey)) ?? defaultSupabaseAnonKey }
        set { d.set(newValue, forKey: Key.supabaseAnonKey) }
    }

    static var identitySecret: String {
        get { d.string(forKey: Key.identitySecret) ?? "" }
        set { d.set(newValue, forKey: Key.identitySecret) }
    }

    // MARK: - Session tokens

    // Dev builds re-sign on every `swift build`, so a Keychain item created by the
    // previous binary triggers a macOS password prompt on each read. UserDefaults
    // avoids that. Harden back to Keychain for the signed Developer ID release.

    /// User's Supabase access token (~1h TTL). Bearer for the portal identity API.
    static var accessToken: String {
        get { d.string(forKey: Key.accessToken) ?? "" }
        set { d.set(newValue, forKey: Key.accessToken) }
    }

    /// Long-lived refresh token. Used by `restore()` on launch to mint a new access token.
    static var refreshToken: String {
        get { d.string(forKey: Key.refreshToken) ?? "" }
        set { d.set(newValue, forKey: Key.refreshToken) }
    }

    static func clearSession() {
        d.removeObject(forKey: Key.accessToken)
        d.removeObject(forKey: Key.refreshToken)
    }

    /// Sign-in is possible once we know the anon key (URL has a baked default).
    static var canSignIn: Bool {
        !supabaseURL.isEmpty && !supabaseAnonKey.isEmpty
    }

    /// The mailbox REST runs on the signed-in user's token (RLS team-gated) —
    /// no service key. Available once signed in.
    static var isConfigured: Bool {
        canSignIn && !accessToken.isEmpty
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

/// Remembers the local `.hotf` project materialized for each HoTF project id,
/// so re-opening reuses it instead of re-downloading all the media every time.
enum HoTFProjectStore {
    private static let key = "hotf.projectFiles"

    static func localURL(for id: String) -> URL? {
        guard let path = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id] else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func remember(_ id: String, url: URL) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        map[id] = url.path
        UserDefaults.standard.set(map, forKey: key)
    }
}

/// The signed-in HoTF account, decoded from `GET /api/identity/resolve`.
struct HoTFAccount: Codable, Equatable {
    var userId: String
    var email: String
    var isTeam: Bool
    var isMasterAdmin: Bool
    var activeStatus: String
    var workspaceSlug: String?
}

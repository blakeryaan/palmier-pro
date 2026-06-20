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
        static let supabaseServiceKey = "hotf.supabaseServiceKey"
        static let accessToken = "hotf.accessToken"
        static let identitySecret = "hotf.identitySecret"
    }

    static let defaultPortalBaseURL = "https://clients.thehotf.com"
    static let defaultSupabaseURL = "https://xxtuqjtwspjcbwvqdfof.supabase.co"

    static var portalBaseURL: String {
        get { nonEmpty(d.string(forKey: Key.portalBaseURL)) ?? defaultPortalBaseURL }
        set { d.set(newValue, forKey: Key.portalBaseURL) }
    }

    static var supabaseURL: String {
        get { nonEmpty(d.string(forKey: Key.supabaseURL)) ?? defaultSupabaseURL }
        set { d.set(newValue, forKey: Key.supabaseURL) }
    }

    static var supabaseServiceKey: String {
        get { d.string(forKey: Key.supabaseServiceKey) ?? "" }
        set { d.set(newValue, forKey: Key.supabaseServiceKey) }
    }

    static var accessToken: String {
        get { d.string(forKey: Key.accessToken) ?? "" }
        set { d.set(newValue, forKey: Key.accessToken) }
    }

    static var identitySecret: String {
        get { d.string(forKey: Key.identitySecret) ?? "" }
        set { d.set(newValue, forKey: Key.identitySecret) }
    }

    static var isConfigured: Bool {
        !supabaseURL.isEmpty && !supabaseServiceKey.isEmpty
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
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

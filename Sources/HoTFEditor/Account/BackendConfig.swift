import Foundation

enum BackendConfig {
    static let clerkPublishableKey: String? = string("HoTFEditorClerkPublishableKey")
    static let convexDeploymentURL: URL? = string("HoTFEditorConvexDeploymentURL").flatMap { URL(string: $0) }
    static let convexHttpURL: URL? = string("HoTFEditorConvexHttpURL").flatMap { URL(string: $0) }

    static var isConfigured: Bool {
        clerkPublishableKey != nil && convexDeploymentURL != nil
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}

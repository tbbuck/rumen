import Foundation
import Security

/// One-off: for a short while cookies were kept in the login keychain, which prompted on every
/// rebuild (decision 17 moved them to the app DB). This reads and removes what is left there.
/// Delete once nobody has a pre-decision-17 build.
enum KeychainMigration {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    private static let service = Bundle.main.bundleIdentifier ?? "ArcGISExplorer"

    private static func query(_ rootURL: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "cookie|" + rootURL.absoluteString]
    }

    static func cookie(forRoot rootURL: URL) -> String? {
        var query = query(rootURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(forRoot rootURL: URL) throws {
        let status = SecItemDelete(query(rootURL) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

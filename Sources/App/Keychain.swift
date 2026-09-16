import Foundation
import Security
import ArcGISKit

/// Per-server secrets in the login keychain, never in the app database (SPEC §5.10, M8
/// acceptance). Items are generic passwords under the app's bundle id, one account per
/// secret and server root.
enum Keychain {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    private static let service = Bundle.main.bundleIdentifier ?? "ArcGISExplorer"

    /// The raw `Cookie` header for a server, as curl's `-b` would send it.
    static func cookie(for server: ServerRecord) -> String? {
        read(account: "cookie|" + server.rootURL.absoluteString)
    }

    static func cookie(forRoot rootURL: URL) -> String? {
        read(account: "cookie|" + rootURL.absoluteString)
    }

    /// Nil or blank removes the item.
    static func setCookie(_ value: String?, forRoot rootURL: URL) throws {
        try write(value?.trimmingCharacters(in: .whitespacesAndNewlines), account: "cookie|" + rootURL.absoluteString)
    }

    // MARK: - Generic passwords

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String?, account: String) throws {
        let base = query(account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var add = base
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}

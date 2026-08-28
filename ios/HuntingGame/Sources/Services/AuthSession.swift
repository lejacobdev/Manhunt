import Foundation
import Combine
import Security

/// Holds the signed-in user's token in the Keychain and exposes it reactively
/// to the rest of the app.
final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    @Published private(set) var token: String?
    @Published private(set) var currentUser: AppUser?

    private let tokenKey = "com.huntinggame.app.jwt"
    private let userDefaultsKey = "com.huntinggame.app.user"

    private init() {
        token = KeychainStore.read(key: tokenKey)
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey) {
            currentUser = try? JSONDecoder().decode(AppUser.self, from: data)
        }
    }

    func signIn(token: String, user: AppUser) {
        self.token = token
        self.currentUser = user
        KeychainStore.save(key: tokenKey, value: token)
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    func signOut() {
        token = nil
        currentUser = nil
        KeychainStore.delete(key: tokenKey)
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    var isAuthenticated: Bool { token != nil && currentUser != nil }
}

/// Minimal Keychain wrapper for storing the JWT; avoids third-party deps for one value.
enum KeychainStore {
    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

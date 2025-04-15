import Foundation
import Security

/// A helper class for interacting with the iOS Keychain to securely save and retrieve data.
class KeychainHelper {
    /// Saves a value in the Keychain for a given key.
    /// - Parameters:
    ///   - key: The key under which the value will be stored.
    ///   - value: The value to be stored in the Keychain.
    static func save(key: String, value: String) {
        if let data = value.data(using: .utf8) {
            let query = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: key,
                kSecValueData: data
            ] as CFDictionary

            SecItemDelete(query)
            SecItemAdd(query, nil)
        }
    }

    /// Retrieves a value from the Keychain for a given key.
    /// - Parameter key: The key for which the value will be retrieved.
    /// - Returns: The value associated with the key, or `nil` if no value is found.
    static func get(key: String) -> String? {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary

        var dataTypeRef: AnyObject?
        if SecItemCopyMatching(query, &dataTypeRef) == noErr {
            if let data = dataTypeRef as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }
}

import Foundation
import Security

/// A singleton manager for handling IoT device credentials stored in the Keychain.
class IoTDeviceManager {
    static let shared = IoTDeviceManager()

    /// The key for storing the device ID in the Keychain.
    private let deviceIdKey = "DEVICE_ID"
    
    /// The key for storing the SAS token in the Keychain.
    private let sasTokenKey = "DEVICE_SAS_TOKEN"

    /// The device ID retrieved from the Keychain.
    var deviceId: String? {
        return readFromKeychain(forKey: deviceIdKey)
    }

    /// The SAS token retrieved from the Keychain.
    var deviceSasToken: String? {
        return readFromKeychain(forKey: sasTokenKey)
    }

    /// Sets up the device credentials by reading them from the Info.plist and saving them to the Keychain.
    func setupDeviceCredentials() {
        if let deviceId = Bundle.main.infoDictionary?[deviceIdKey] as? String, !deviceId.isEmpty {
            saveToKeychain(value: deviceId, forKey: deviceIdKey)
        }
        if let token = Bundle.main.infoDictionary?[sasTokenKey] as? String, !token.isEmpty {
            saveToKeychain(value: token, forKey: sasTokenKey)
        }        
    }

    /// Saves a value to the Keychain for a given key.
    /// - Parameters:
    ///   - value: The value to save.
    ///   - key: The key under which the value will be stored.
    private func saveToKeychain(value: String, forKey key: String) {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary) // Remove if already exists
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Reads a value from the Keychain for a given key.
    /// - Parameter key: The key for which the value will be retrieved.
    /// - Returns: The value associated with the key, or `nil` if no value is found.
    private func readFromKeychain(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess,
           let data = dataTypeRef as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        return nil
    }
}

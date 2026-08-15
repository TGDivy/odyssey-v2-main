import Foundation
import OdysseyDomain
#if canImport(Security)
import Security
#endif

public struct StoredRefreshCredential: Codable, Hashable, Sendable {
    public let deviceID: UUIDv7
    public let value: String
    public let expiresAt: Date

    public init(deviceID: UUIDv7, value: String, expiresAt: Date) throws {
        guard (32 ... 512).contains(value.count),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              expiresAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw CredentialVaultError.invalidCredential
        }
        self.deviceID = deviceID
        self.value = value
        self.expiresAt = expiresAt
    }
}

public enum CredentialVaultError: Error, Equatable, Sendable {
    case unavailable
    case invalidConfiguration
    case invalidDeviceIdentifier
    case invalidCredential
    case deviceMismatch
    case keychain(status: Int32)
}

public protocol CredentialVault: Sendable {
    func loadOrCreateDeviceID() async throws -> UUIDv7
    func refreshCredential() async throws -> StoredRefreshCredential?
    func storeRefreshCredential(_ credential: StoredRefreshCredential) async throws
    func clearRefreshCredential() async throws
    func clearAll() async throws
}

public struct KeychainCredentialConfiguration: Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }
}

public actor KeychainCredentialVault: CredentialVault {
    private let configuration: KeychainCredentialConfiguration
    private let deviceAccount = "odyssey.device-id.v1"
    private let refreshAccount = "odyssey.refresh-credential.v1"

    public init(configuration: KeychainCredentialConfiguration) throws {
        guard !configuration.service.isEmpty,
              configuration.service == configuration.service.trimmingCharacters(in: .whitespacesAndNewlines),
              configuration.accessGroup?.isEmpty != true
        else {
            throw CredentialVaultError.invalidConfiguration
        }
        self.configuration = configuration
    }

    public func loadOrCreateDeviceID() async throws -> UUIDv7 {
        #if canImport(Security)
        if let data = try read(account: deviceAccount) {
            return try decodeDeviceID(data)
        }
        let deviceID = UUIDv7()
        let data = Data(deviceID.description.utf8)
        do {
            try add(data, account: deviceAccount)
            return deviceID
        } catch CredentialVaultError.keychain(let status) where status == errSecDuplicateItem {
            guard let existing = try read(account: deviceAccount) else {
                throw CredentialVaultError.keychain(status: status)
            }
            return try decodeDeviceID(existing)
        }
        #else
        throw CredentialVaultError.unavailable
        #endif
    }

    public func refreshCredential() async throws -> StoredRefreshCredential? {
        #if canImport(Security)
        guard let data = try read(account: refreshAccount) else {
            return nil
        }
        do {
            let decoded = try decoder().decode(StoredRefreshCredential.self, from: data)
            let credential = try StoredRefreshCredential(
                deviceID: decoded.deviceID,
                value: decoded.value,
                expiresAt: decoded.expiresAt
            )
            let deviceID = try await loadOrCreateDeviceID()
            guard credential.deviceID == deviceID else {
                throw CredentialVaultError.deviceMismatch
            }
            return credential
        } catch let error as CredentialVaultError {
            throw error
        } catch {
            throw CredentialVaultError.invalidCredential
        }
        #else
        throw CredentialVaultError.unavailable
        #endif
    }

    public func storeRefreshCredential(_ credential: StoredRefreshCredential) async throws {
        #if canImport(Security)
        let deviceID = try await loadOrCreateDeviceID()
        guard credential.deviceID == deviceID else {
            throw CredentialVaultError.deviceMismatch
        }
        let data: Data
        do {
            data = try encoder().encode(credential)
        } catch {
            throw CredentialVaultError.invalidCredential
        }
        if try read(account: refreshAccount) == nil {
            try add(data, account: refreshAccount)
        } else {
            try update(data, account: refreshAccount)
        }
        #else
        throw CredentialVaultError.unavailable
        #endif
    }

    public func clearRefreshCredential() async throws {
        #if canImport(Security)
        try delete(account: refreshAccount)
        #else
        throw CredentialVaultError.unavailable
        #endif
    }

    public func clearAll() async throws {
        #if canImport(Security)
        try delete(account: refreshAccount)
        try delete(account: deviceAccount)
        #else
        throw CredentialVaultError.unavailable
        #endif
    }

    #if canImport(Security)
    private func query(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func read(account: String) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialVaultError.keychain(status: status)
        }
        return data
    }

    private func add(_ data: Data, account: String) throws {
        var attributes = query(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialVaultError.keychain(status: status)
        }
    }

    private func update(_ data: Data, account: String) throws {
        let status = SecItemUpdate(
            query(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw CredentialVaultError.keychain(status: status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.keychain(status: status)
        }
    }

    private func decodeDeviceID(_ data: Data) throws -> UUIDv7 {
        guard let value = String(data: data, encoding: .utf8),
              let identifier = UUID(uuidString: value)
        else {
            throw CredentialVaultError.invalidDeviceIdentifier
        }
        do {
            return try UUIDv7(validating: identifier)
        } catch {
            throw CredentialVaultError.invalidDeviceIdentifier
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
    #endif
}

import Foundation
import Security

/// A process-lifetime cache. Reads, writes and interaction-policy scopes are
/// serialized together, including missing or denied reads.
final class CredentialSession {
    enum ReadResult { case value(String), missing, blocked(OSStatus) }
    private let lock = NSRecursiveLock()
    private let read: (Bool) -> ReadResult
    private let write: (String) throws -> Void
    private let delete: () -> OSStatus
    private var loaded = false
    private var value: String?
    private var status: OSStatus?

    init(read: @escaping (Bool) -> ReadResult, write: @escaping (String) throws -> Void,
         delete: @escaping () -> OSStatus = { errSecUnimplemented }) {
        self.read = read; self.write = write; self.delete = delete
    }

    func get() -> String? {
        lock.lock(); defer { lock.unlock() }
        if !loaded { apply(read(false)) }
        return value
    }

    /// Only an explicit user action may retry a blocked read with authentication UI.
    func unlock() -> String? {
        lock.lock(); defer { lock.unlock() }
        apply(read(true))
        return value
    }

    func set(_ newValue: String) throws {
        lock.lock(); defer { lock.unlock() }
        try write(newValue)
        // A failed write leaves both the stored credential and session cache intact.
        apply(.value(newValue))
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        let result = delete()
        if result == errSecSuccess || result == errSecItemNotFound { apply(.missing) }
    }

    var cachedReadStatus: OSStatus? {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    var cachedFingerprint: String? {
        lock.lock(); defer { lock.unlock() }
        return value.map { String($0.suffix(4)) }
    }

    private func apply(_ result: ReadResult) {
        loaded = true
        switch result {
        case .value(let credential):
            value = credential.isEmpty ? nil : credential
            status = credential.isEmpty ? errSecItemNotFound : errSecSuccess
        case .missing: value = nil; status = errSecItemNotFound
        case .blocked(let failure): value = nil; status = failure
        }
    }
}

/// Each provider has its own cache and account. Legacy credentials stay in place.
final class CredentialVault {
    private let sessions: [ConnectionProvider: CredentialSession]
    init(read: @escaping (ConnectionProvider, Bool) -> CredentialSession.ReadResult,
         write: @escaping (ConnectionProvider, String) throws -> Void) {
        sessions = Dictionary(uniqueKeysWithValues: ConnectionProvider.allCases.map { provider in
            (provider, CredentialSession(read: { read(provider, $0) }, write: { try write(provider, $0) }))
        })
    }
    func get(_ provider: ConnectionProvider) -> String? { sessions[provider]!.get() }
    func unlock(_ provider: ConnectionProvider) -> String? { sessions[provider]!.unlock() }
    func set(_ value: String, for provider: ConnectionProvider) throws { try sessions[provider]!.set(value) }
    func status(_ provider: ConnectionProvider) -> OSStatus? { sessions[provider]!.cachedReadStatus }
    func fingerprint(_ provider: ConnectionProvider) -> String? { sessions[provider]!.cachedFingerprint }
}

/// Injectable access keeps provider-selection tests completely outside the real Keychain.
struct CredentialAccess {
    var get: (ConnectionProvider) -> String?
    var unlock: (ConnectionProvider) -> String?
    var set: (String, ConnectionProvider) throws -> Void
    var status: (ConnectionProvider) -> OSStatus?
    var fingerprint: (ConnectionProvider) -> String?
    var legacyConfigured: () -> Bool
    func needsAccess(_ provider: ConnectionProvider) -> Bool {
        guard let status = status(provider) else { return false }
        return status != errSecSuccess && status != errSecItemNotFound
    }
    static var live: CredentialAccess {
        CredentialAccess(get: { Keychain.get(for: $0) }, unlock: { Keychain.unlock(for: $0) },
            set: { try Keychain.set($0, for: $1) }, status: { Keychain.cachedReadStatus(for: $0) },
            fingerprint: { Keychain.cachedFingerprint(for: $0) }, legacyConfigured: {
                _ = Keychain.get(for: .team)
                // An inaccessible old item is still an existing Team configuration.
                return Keychain.cachedReadStatus(for: .team) != errSecItemNotFound
            })
    }
}

/// Routine app use never asks for Keychain access. Explicit unlock/save may authenticate.
/// The interaction-policy lock is shared by all accounts because the policy is process-wide.
enum Keychain {
    static let service = "com.sebastianmarambio.transcribe"
    static func account(for provider: ConnectionProvider) -> String {
        provider == .team ? "openai-api-key" : "direct-openai-api-key"
    }
    private static let interactionLock = NSRecursiveLock()
    private static let vault = CredentialVault(read: { read(provider: $0, interactive: $1) },
                                               write: { try write($1, provider: $0) })

    struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "The credential could not be saved in Keychain (\(status)). Your previous credential was kept."
        }
    }
    static func get(for provider: ConnectionProvider) -> String? { vault.get(provider) }
    static func unlock(for provider: ConnectionProvider) -> String? { vault.unlock(provider) }
    static func set(_ value: String, for provider: ConnectionProvider) throws { try vault.set(value, for: provider) }
    static func cachedReadStatus(for provider: ConnectionProvider) -> OSStatus? { vault.status(provider) }
    static func cachedFingerprint(for provider: ConnectionProvider) -> String? { vault.fingerprint(provider) }

    private static func query(for provider: ConnectionProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account(for: provider)]
    }
    private static func withInteraction<T>(_ allowed: Bool, _ body: () throws -> T) throws -> T {
        interactionLock.lock(); defer { interactionLock.unlock() }
        var previous: DarwinBoolean = false
        let getStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard getStatus == errSecSuccess else { throw StorageError(status: getStatus) }
        let setStatus = SecKeychainSetUserInteractionAllowed(allowed)
        guard setStatus == errSecSuccess else { throw StorageError(status: setStatus) }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try body()
    }
    private static func read(provider: ConnectionProvider, interactive: Bool) -> CredentialSession.ReadResult {
        do {
            return try withInteraction(interactive) {
                var lookup = query(for: provider)
                lookup[kSecReturnData as String] = true
                lookup[kSecMatchLimit as String] = kSecMatchLimitOne
                if !interactive { lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
                var item: CFTypeRef?
                let status = SecItemCopyMatching(lookup as CFDictionary, &item)
                if status == errSecItemNotFound { return .missing }
                guard status == errSecSuccess else { return .blocked(status) }
                guard let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
                else { return .missing }
                return .value(value)
            }
        } catch let error as StorageError { return .blocked(error.status) }
        catch { return .blocked(errSecInternalComponent) }
    }
    private static func write(_ value: String, provider: ConnectionProvider) throws {
        try withInteraction(true) {
            let query = query(for: provider)
            let data = Data(value.utf8)
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw StorageError(status: update) }
            var add = query; add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw StorageError(status: status) }
        }
    }
}

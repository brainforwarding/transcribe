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

/// Keeps the existing file-based item and app-scoped ACL. Routine app use never
/// asks for Keychain access; an explicit unlock or save may authenticate once.
enum Keychain {
    static let service = "com.sebastianmarambio.transcribe"
    static let account = "openai-api-key"
    private static let session = CredentialSession(read: read, write: write, delete: delete)

    struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "The credential could not be saved in Keychain (\(status)). Your previous credential was kept."
        }
    }

    static func get() -> String? { session.get() }
    static func unlock() -> String? { session.unlock() }
    static func set(_ value: String) throws { try session.set(value) }
    static func clear() { session.clear() }
    static var cachedReadStatus: OSStatus? { session.cachedReadStatus }
    static var cachedFingerprint: String? { session.cachedFingerprint }
    static var needsAccess: Bool {
        guard let status = cachedReadStatus else { return false }
        return status != errSecSuccess && status != errSecItemNotFound
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// SecItem's UI flags do not guarantee silence for legacy/file-based items.
    /// All callers hold the session lock while changing this process-wide setting.
    private static func withInteraction<T>(_ allowed: Bool, _ body: () throws -> T) throws -> T {
        var previous: DarwinBoolean = false
        let getStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard getStatus == errSecSuccess else { throw StorageError(status: getStatus) }
        let setStatus = SecKeychainSetUserInteractionAllowed(allowed)
        guard setStatus == errSecSuccess else { throw StorageError(status: setStatus) }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try body()
    }

    private static func read(interactive: Bool) -> CredentialSession.ReadResult {
        do {
            return try withInteraction(interactive) {
                var lookup = query
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

    private static func write(_ value: String) throws {
        try withInteraction(true) {
            let data = Data(value.utf8)
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw StorageError(status: update) }
            var add = query; add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw StorageError(status: status) }
        }
    }

    private static func delete() -> OSStatus {
        // Existing explicit removal behavior; it cannot cause an implicit prompt.
        (try? withInteraction(false) { SecItemDelete(query as CFDictionary) }) ?? errSecInteractionNotAllowed
    }
}

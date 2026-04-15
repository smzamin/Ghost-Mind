import Foundation

// MARK: - KeyValueStore

protocol KeyValueStore {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func removeValue(forKey key: String)
}

// MARK: - UserDefaultsStore

struct UserDefaultsStore: KeyValueStore {
    private let defaults: UserDefaults
    private let prefix: String

    init(defaults: UserDefaults = .standard, prefix: String) {
        self.defaults = defaults
        self.prefix = prefix
    }

    private func k(_ key: String) -> String { "\(prefix)\(key)" }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: k(key))
    }

    func set(_ value: String?, forKey key: String) {
        let key = k(key)
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func removeValue(forKey key: String) {
        defaults.removeObject(forKey: k(key))
    }
}

// MARK: - InMemoryStore

final class InMemoryStore: KeyValueStore {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private let prefix: String

    init(prefix: String) {
        self.prefix = prefix
    }

    private func k(_ key: String) -> String { "\(prefix)\(key)" }

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[k(key)]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = k(key)
        if let value { storage[key] = value }
        else { storage.removeValue(forKey: key) }
    }

    func removeValue(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: k(key))
    }
}

// MARK: - Codable helpers

extension KeyValueStore {
    func codableValue<T: Codable>(forKey key: String, as type: T.Type) -> T? {
        guard let json = string(forKey: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setCodableValue<T: Codable>(_ value: T?, forKey key: String) {
        guard let value else {
            removeValue(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        set(json, forKey: key)
    }
}


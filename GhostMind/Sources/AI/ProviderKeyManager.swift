import Foundation
import SwiftUI

// MARK: - ProviderKeyManager
//
// Manages multiple API keys per provider with:
// • Round-robin rotation across keys
// • Automatic quota-cooldown tracking (15-min window)
// • Instant fallback when active pool exhausted
// • Local persistence per provider (UserDefaults by default)
// • Best-effort migration from legacy single-key storage

@MainActor
final class ProviderKeyManager: ObservableObject {
    private let store: KeyValueStore

    // MARK: - Key Entry

    struct KeyEntry: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var key: String = ""
        var label: String = ""          // optional human label
        var isEnabled: Bool = true
        var failCount: Int = 0
        var cooldownUntil: Date?

        var isAvailable: Bool {
            guard isEnabled, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            if let until = cooldownUntil, Date() < until { return false }
            return true
        }

        var status: KeyStatus {
            if key.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
            if !isEnabled { return .disabled }
            if let until = cooldownUntil, Date() < until {
                let mins = Int(until.timeIntervalSinceNow / 60) + 1
                return .cooldown(mins)
            }
            if failCount > 0 { return .degraded(failCount) }
            return .active
        }
    }

    enum KeyStatus {
        case active
        case degraded(Int)
        case cooldown(Int)
        case disabled
        case empty

        var label: String {
            switch self {
            case .active:          return "Active"
            case .degraded(let n): return "\(n) fail\(n == 1 ? "" : "s")"
            case .cooldown(let m): return "Cooldown ~\(m)m"
            case .disabled:        return "Disabled"
            case .empty:           return "Empty"
            }
        }

        var color: Color {
            switch self {
            case .active:    return .green
            case .degraded:  return .yellow
            case .cooldown:  return .orange
            case .disabled:  return .secondary
            case .empty:     return .secondary
            }
        }

        var icon: String {
            switch self {
            case .active:    return "checkmark.circle.fill"
            case .degraded:  return "exclamationmark.triangle.fill"
            case .cooldown:  return "clock.fill"
            case .disabled:  return "minus.circle.fill"
            case .empty:     return "circle"
            }
        }
    }

    // MARK: - Provider Config

    struct ProviderConfig: Codable {
        var keys: [KeyEntry] = []
        var customModel: String = ""
        var customBaseURL: String = ""
        var roundRobinIndex: Int = 0
    }

    // MARK: - State

    @Published var configs: [String: ProviderConfig] = {
        var c: [String: ProviderConfig] = [:]
        for p in AIProvider.allCases { c[p.rawValue] = ProviderConfig() }
        return c
    }()

    static let cooldownDuration: TimeInterval = 15 * 60   // 15 minutes
    static let maxRetryPerKey:   Int           = 2         // failures before cooldown

    // MARK: - Init

    init(store: KeyValueStore = UserDefaultsStore(prefix: "ghostmind.pkm.")) {
        self.store = store
        loadAll()
        migrateFromSingleKeyStorage()
    }

    // MARK: - Read helpers

    func config(for provider: AIProvider) -> ProviderConfig {
        configs[provider.rawValue] ?? ProviderConfig()
    }

    func customModel(for provider: AIProvider) -> String {
        config(for: provider).customModel
    }

    func effectiveModel(for provider: AIProvider, clientModel: String) -> String {
        let custom = customModel(for: provider)
        if !custom.isEmpty { return custom }
        if !clientModel.isEmpty { return clientModel }
        return provider.defaultModel
    }

    func customBaseURL(for provider: AIProvider) -> String {
        config(for: provider).customBaseURL
    }

    func effectiveBaseURL(for provider: AIProvider) -> String {
        let custom = customBaseURL(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return provider.baseURL
    }

    func availableKeys(for provider: AIProvider) -> [KeyEntry] {
        config(for: provider).keys.filter { $0.isAvailable }
    }

    func hasKeys(for provider: AIProvider) -> Bool {
        !config(for: provider).keys.filter { !$0.key.isEmpty }.isEmpty
    }

    // MARK: - Round-Robin Rotation

    /// Returns the next available key in round-robin order.
    /// Returns `nil` if all keys are exhausted / cooling down.
    func nextAvailableKey(for provider: AIProvider) -> KeyEntry? {
        var cfg = config(for: provider)
        let pool = cfg.keys.filter { $0.isAvailable }
        guard !pool.isEmpty else { return nil }

        let idx = cfg.roundRobinIndex % pool.count
        let entry = pool[idx]
        cfg.roundRobinIndex = (cfg.roundRobinIndex + 1) % pool.count
        configs[provider.rawValue] = cfg
        return entry
    }

    // MARK: - Failure Tracking

    func markKeyFailed(id: UUID, for provider: AIProvider, isQuotaExceeded: Bool) {
        guard var cfg = configs[provider.rawValue] else { return }
        if let i = cfg.keys.firstIndex(where: { $0.id == id }) {
            cfg.keys[i].failCount += 1
            if isQuotaExceeded || cfg.keys[i].failCount >= Self.maxRetryPerKey {
                cfg.keys[i].cooldownUntil = Date().addingTimeInterval(Self.cooldownDuration)
            }
        }
        configs[provider.rawValue] = cfg
        persist(provider.rawValue)
    }

    func resetKey(id: UUID, for provider: AIProvider) {
        guard var cfg = configs[provider.rawValue] else { return }
        if let i = cfg.keys.firstIndex(where: { $0.id == id }) {
            cfg.keys[i].cooldownUntil = nil
            cfg.keys[i].failCount = 0
            cfg.keys[i].isEnabled = true
        }
        configs[provider.rawValue] = cfg
        persist(provider.rawValue)
    }

    func resetAllKeys(for provider: AIProvider) {
        guard var cfg = configs[provider.rawValue] else { return }
        for i in cfg.keys.indices {
            cfg.keys[i].cooldownUntil = nil
            cfg.keys[i].failCount = 0
        }
        configs[provider.rawValue] = cfg
        persist(provider.rawValue)
    }

    // MARK: - CRUD

    func addKey(to provider: AIProvider) {
        guard var cfg = configs[provider.rawValue] else { return }
        cfg.keys.append(KeyEntry())
        configs[provider.rawValue] = cfg
        // Don't persist yet — user hasn't typed a key
    }

    func removeKey(id: UUID, from provider: AIProvider) {
        guard var cfg = configs[provider.rawValue] else { return }
        cfg.keys.removeAll { $0.id == id }
        configs[provider.rawValue] = cfg
        persist(provider.rawValue)
    }

    func updateKey(id: UUID, for provider: AIProvider, newKey: String) {
        guard var cfg = configs[provider.rawValue] else { return }
        if let i = cfg.keys.firstIndex(where: { $0.id == id }) {
            cfg.keys[i].key = newKey
            // Reset failure state when user updates the key
            cfg.keys[i].failCount = 0
            cfg.keys[i].cooldownUntil = nil
        }
        configs[provider.rawValue] = cfg
        persist(provider.rawValue)
    }

    func updateLabel(id: UUID, for provider: AIProvider, label: String) {
        guard var cfg = configs[provider.rawValue] else { return }
        if let i = cfg.keys.firstIndex(where: { $0.id == id }) {
            cfg.keys[i].label = label
        }
        configs[provider.rawValue] = cfg
        persist(provider.rawValue)
    }

    func toggleKey(id: UUID, for provider: AIProvider) {
        guard var cfg = configs[provider.rawValue] else { return }
        if let i = cfg.keys.firstIndex(where: { $0.id == id }) {
            cfg.keys[i].isEnabled.toggle()
            // Reset cooldown when re-enabling
            if cfg.keys[i].isEnabled {
                cfg.keys[i].cooldownUntil = nil
                cfg.keys[i].failCount = 0
            }
        }
        configs[provider.rawValue] = cfg
        persist(provider.rawValue)
    }

    func setCustomModel(_ model: String, for provider: AIProvider) {
        guard var cfg = configs[provider.rawValue] else { return }
        cfg.customModel = model
        configs[provider.rawValue] = cfg
        persist(provider.rawValue)
    }

    func setCustomBaseURL(_ url: String, for provider: AIProvider) {
        guard var cfg = configs[provider.rawValue] else { return }
        cfg.customBaseURL = url
        configs[provider.rawValue] = cfg
        persist(provider.rawValue)
    }

    // MARK: - Persistence

    private func persist(_ providerRaw: String) {
        store.setCodableValue(configs[providerRaw], forKey: "pkm_v1_\(providerRaw)")
    }

    private func loadAll() {
        for provider in AIProvider.allCases {
            let k = "pkm_v1_\(provider.rawValue)"
            if let cfg = store.codableValue(forKey: k, as: ProviderConfig.self) {
                configs[provider.rawValue] = cfg
            }
        }
    }

    /// Best-effort migration of old single-key storage into the multi-key system
    private func migrateFromSingleKeyStorage() {
        for provider in AIProvider.allCases {
            let rawKey = store.string(forKey: "legacy_single_key_\(provider.rawValue)") ?? ""
            guard !rawKey.isEmpty else { continue }
            var cfg = config(for: provider)
            let alreadyMigrated = cfg.keys.contains { $0.key == rawKey }
            if !alreadyMigrated {
                cfg.keys.insert(KeyEntry(id: UUID(), key: rawKey, label: "Imported"), at: 0)
                configs[provider.rawValue] = cfg
                persist(provider.rawValue)
            }
        }
    }
}

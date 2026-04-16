import Foundation
import Combine

@propertyWrapper
struct Persist<T: Codable> {
    let key: String
    let defaultValue: T
    private let store = UserDefaults.standard

    var wrappedValue: T {
        get {
            guard let data = store.object(forKey: key) as? Data else { return defaultValue }
            return (try? JSONDecoder().decode(T.self, from: data)) ?? defaultValue
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                store.set(data, forKey: key)
            }
        }
    }
}

// Specialization for simple types like Bool/String/Double that don't need full Codable (though they are Codable)
@propertyWrapper
struct PersistRaw<T> {
    let key: String
    let defaultValue: T
    private let store = UserDefaults.standard

    var wrappedValue: T {
        get { (store.object(forKey: key) as? T) ?? defaultValue }
        set { store.set(newValue, forKey: key) }
    }
}

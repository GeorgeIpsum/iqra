// App/Sources/ReaderSettingsStore.swift
import Foundation
import IqraReader

/// Global appearance settings, persisted as JSON in UserDefaults. Per-book overrides are
/// a later milestone; the schema-level home for synced settings arrives with M7.
enum ReaderSettingsStore {
    private static let key = "reader.settings.v1"

    static func load() -> ReaderSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ReaderSettings.self, from: data)
        else { return .default }
        return settings
    }

    static func save(_ settings: ReaderSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

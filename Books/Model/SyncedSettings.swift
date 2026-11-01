import Foundation

/// Mirrors app-wide preferences between UserDefaults and `Reading Data/Settings.plist`, so every Mac
/// sharing the library shares them. Each key keeps its own timestamp; the newest write wins.
/// Per-Mac values (Claude path, open book, window state, file paths) stay out.
@MainActor
final class SyncedSettings {
    static let shared = SyncedSettings()

    static let keys = ["readerPreferences", "librarySort", "coverSize", "autoCopyOpenedBooks",
                       "claudeModel", "claudeEffort", "chatFont", "chatTextSize"]
    private static let updatedKey = "syncedSettingsUpdated"

    private var fileURL: URL?
    private var snapshot: [String: Any] = [:]
    private var updated: [String: Date]
    private var observer: NSObjectProtocol?
    private var pushTask: Task<Void, Never>?

    private init() {
        updated = UserDefaults.standard.dictionary(forKey: Self.updatedKey) as? [String: Date] ?? [:]
    }

    func attach(to dataURL: URL) {
        fileURL = dataURL.appendingPathComponent("Settings.plist")
        snapshot = Self.localValues()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.localChanged() }
            }
        }
        sync()
    }

    func isSettingsFile(_ path: String) -> Bool { path == fileURL?.path }

    /// Reads the shared file, applies newer values here, and writes back anything newer here.
    func sync() {
        pushTask?.cancel()
        pushTask = nil
        guard let fileURL else { return }
        let local = snapshot.filter { Self.keys.contains($0.key) }
        let localUpdated = updated
        var remote: [String: Any] = [:]
        var remoteUpdated: [String: Date] = [:]
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forMerging, error: &coordinationError) { u in
            if let data = try? Data(contentsOf: u),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                remote = plist["values"] as? [String: Any] ?? [:]
                remoteUpdated = plist["updated"] as? [String: Date] ?? [:]
            }
            var values = remote, stamps = remoteUpdated
            for (key, value) in local where (localUpdated[key] ?? .distantPast) > (remoteUpdated[key] ?? .distantPast) || remote[key] == nil {
                values[key] = value
                stamps[key] = localUpdated[key] ?? .distantPast
            }
            guard !Self.equal(values, remote) || stamps != remoteUpdated,
                  let data = try? PropertyListSerialization.data(fromPropertyList: ["values": values, "updated": stamps],
                                                                 format: .xml, options: 0) else { return }
            try? data.write(to: u, options: .atomic)
        }

        var applied = false
        for key in Self.keys {
            guard let value = remote[key], let stamp = remoteUpdated[key],
                  stamp > (localUpdated[key] ?? .distantPast) || local[key] == nil,
                  !Self.equal(value, local[key]) else { continue }
            snapshot[key] = value
            updated[key] = stamp
            UserDefaults.standard.set(value, forKey: key)
            applied = true
        }
        if applied {
            UserDefaults.standard.set(updated, forKey: Self.updatedKey)
            ReaderSettings.shared.reloadFromDefaults()
        }
    }

    private func localChanged() {
        let now = Self.localValues()
        let changed = Self.keys.filter { !Self.equal(now[$0], snapshot[$0]) }
        snapshot = now
        guard !changed.isEmpty else { return }
        let stamp = Date()
        for key in changed { updated[key] = stamp }
        UserDefaults.standard.set(updated, forKey: Self.updatedKey)
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { sync() }
        }
    }

    private static func localValues() -> [String: Any] {
        var values: [String: Any] = [:]
        for key in keys { if let v = UserDefaults.standard.object(forKey: key) { values[key] = v } }
        return values
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b)
        default: false
        }
    }
}

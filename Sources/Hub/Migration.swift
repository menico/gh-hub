import Foundation

/// The app was called Hub (io.github.menico.hub) before it became GH Hub.
/// Brings its preferences and saved reviews along, once.
enum Migration {
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromHub") else { return }
        // The installed app's preferences first, then a development build's for anything missing.
        for domain in ["io.github.menico.hub", "hub-app"] {
            for (key, value) in defaults.persistentDomain(forName: domain) ?? [:]
            where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") {
                defaults.set(value, forKey: key)
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("io.github.menico.hub/reviews", isDirectory: true)
        let new = support.appendingPathComponent("io.github.menico.gh-hub/reviews", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: new.path) {
            try? FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: old, to: new)
        }
        defaults.set(true, forKey: "migratedFromHub")
    }
}

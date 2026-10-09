import Foundation

/// Where learned words, habits, pairs, and curves are stored.
///
/// The App Group is used when Full Access makes it available, so the companion can
/// read the same files. Without it, the extension's own container is used. Settings
/// the companion must read do not come through here.
enum LearningDirectory {
    static func fileURL(named name: String) -> URL? {
        if let shared = SharedContainer.fileURL(named: name) {
            return shared
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appending(path: "LeanType", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name, directoryHint: .notDirectory)
    }
}

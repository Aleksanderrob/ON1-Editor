import CryptoKit
import Foundation

enum TripStore {
    static func appDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ON1Editor", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func cacheDirectory() throws -> URL {
        let url = try appDirectory().appendingPathComponent("Previews", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load(for folder: URL) -> TripPreferences {
        guard let data = try? Data(contentsOf: stateURL(for: folder)),
              let state = try? JSONDecoder().decode(TripPreferences.self, from: data) else {
            return TripPreferences()
        }
        return state
    }

    static func save(_ state: TripPreferences, for folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL(for: folder), options: .atomic)
    }

    private static func stateURL(for folder: URL) -> URL {
        let hash = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let base = (try? appDirectory()) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("trip-\(hash).json")
    }
}

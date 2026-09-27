import AppKit
import CryptoKit
import Foundation

enum PixelAdjustment {
    @inline(__always)
    static func apply(red: Double, green: Double, blue: Double,
                      plan: EditPlan) -> (Double, Double, Double) {
        let exposure = pow(2, plan.exposureEV)
        var r = (red * exposure - 0.5) * plan.contrast + 0.5
        var g = (green * exposure - 0.5) * plan.contrast + 0.5
        var b = (blue * exposure - 0.5) * plan.contrast + 0.5
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r = min(max((luma + (r - luma) * plan.saturation) * (1 + plan.warmth * 0.28), 0), 1)
        g = min(max(luma + (g - luma) * plan.saturation, 0), 1)
        b = min(max((luma + (b - luma) * plan.saturation) * (1 - plan.warmth * 0.28), 0), 1)
        return (r, g, b)
    }
}

enum CubeLUT {
    static let dimension = 17

    static func write(_ plan: EditPlan, to url: URL) throws {
        var result = "TITLE \"ON1 Editor individual look\"\n"
        result += "LUT_3D_SIZE \(dimension)\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let colour = PixelAdjustment.apply(
                        red: Double(red) / Double(dimension - 1),
                        green: Double(green) / Double(dimension - 1),
                        blue: Double(blue) / Double(dimension - 1), plan: plan)
                    result += String(format: "%.6f %.6f %.6f\n", locale: Locale(identifier: "en_US_POSIX"),
                                     colour.0, colour.1, colour.2)
                }
            }
        }
        try result.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct ON1HandoffManifest: Codable {
    struct Item: Codable {
        let photo: String
        let look: String
        let plan: String
        let preview: String?
        let scene: PhotoScene
    }

    let formatVersion: Int
    let createdAt: Date
    let selected: [Item]
    let references: [String]
    let exportLongEdge: Int?
}

enum ON1HandoffError: LocalizedError {
    case noSelectedPlans
    case missingSource(URL)

    var errorDescription: String? {
        switch self {
        case .noSelectedPlans: return "Choose JPEG references and selected photos before preparing ON1."
        case .missingSource(let url): return "Could not find \(url.lastPathComponent)."
        }
    }
}

struct ON1Handoff {
    let packageURL: URL
    let photosURL: URL
    let count: Int
}

enum ON1Bridge {
    static func installedApplication() -> URL? {
        if let found = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.ononesoftware.ON1PhotoRAW2026.premium") { return found }
        let fallback = URL(fileURLWithPath:
            "/Applications/ON1 Photo RAW 2026/ON1 Photo RAW 2026.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static func prepare(selected: [PhotoRecord], references: [PhotoRecord],
                        in destination: URL, exportLongEdge: Int?) throws -> ON1Handoff {
        let editable = selected.compactMap { photo -> (PhotoRecord, EditPlan)? in
            guard let plan = photo.plan else { return nil }
            return (photo, plan)
        }
        guard !editable.isEmpty else { throw ON1HandoffError.noSelectedPlans }
        let files = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let base = "ON1 Editor Handoff \(formatter.string(from: Date()))"
        var package = destination.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while files.fileExists(atPath: package.path) {
            package = destination.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        let photos = package.appendingPathComponent("Photos to Edit", isDirectory: true)
        let referenceFolder = package.appendingPathComponent("Style References", isDirectory: true)
        let looks = package.appendingPathComponent("Individual Looks", isDirectory: true)
        let previews = package.appendingPathComponent("Edited Previews", isDirectory: true)
        do {
            for folder in [photos, referenceFolder, looks, previews] {
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            var items: [ON1HandoffManifest.Item] = []
            for (photo, plan) in editable {
                guard files.fileExists(atPath: photo.sourceURL.path) else {
                    throw ON1HandoffError.missingSource(photo.sourceURL)
                }
                let stem = uniqueStem(for: photo)
                let extensionName = photo.sourceURL.pathExtension.lowercased()
                let photoName = "\(stem).\(extensionName)"
                let lookName = "\(stem).cube"
                let planName = "\(stem).json"
                try files.copyItem(at: photo.sourceURL, to: photos.appendingPathComponent(photoName))
                try CubeLUT.write(plan, to: looks.appendingPathComponent(lookName))
                try encode(plan, to: looks.appendingPathComponent(planName))
                let previewName: String?
                if let preview = photo.editedPreviewURL, files.fileExists(atPath: preview.path) {
                    let name = "\(stem).jpg"
                    try files.copyItem(at: preview, to: previews.appendingPathComponent(name))
                    previewName = name
                } else { previewName = nil }
                items.append(.init(photo: photoName, look: lookName, plan: planName,
                                   preview: previewName, scene: photo.scene))
            }
            var referenceNames: [String] = []
            var seenReferences = Set<String>()
            for reference in references where seenReferences.insert(reference.sourceURL.path).inserted {
                guard files.fileExists(atPath: reference.sourceURL.path) else {
                    throw ON1HandoffError.missingSource(reference.sourceURL)
                }
                let name = "\(uniqueStem(for: reference)).\(reference.sourceURL.pathExtension.lowercased())"
                try files.copyItem(at: reference.sourceURL, to: referenceFolder.appendingPathComponent(name))
                referenceNames.append(name)
            }
            let manifest = ON1HandoffManifest(formatVersion: 1, createdAt: Date(),
                selected: items, references: referenceNames, exportLongEdge: exportLongEdge)
            try encode(manifest, to: package.appendingPathComponent("Handoff.json"))
            let sizeNote = exportLongEdge.map { "\($0) pixels on the long edge" } ?? "original size"
            let instructions = """
            ON1 EDITOR HANDOFF

            Photos to Edit contains copies of only the selected photos. Your originals are untouched.
            Style References contains the reference images used to plan the look.
            Individual Looks contains a separate .cube LUT and JSON plan for every photo.
            Edited Previews shows the intended look at preview resolution.

            In ON1 Photo RAW 2026, choose Browse Folder and select Photos to Edit.
            ON1 may show its Home screen or previous folder when launched. In ON1's Edit module,
            import or select the matching .cube LUT for each photo, then compare it with
            the Edited Preview and fine-tune the RAW development settings. The LUT is an
            approximate transfer of the editor's colour and tone plan; it does not apply
            itself automatically or replace ON1's RAW controls.

            Export the finished photos from ON1 to your chosen folder at \(sizeNote).
            Handoff.json pairs each staged photo with its individual LUT and plan.
            """
            try instructions.write(to: package.appendingPathComponent("READ ME.txt"),
                                   atomically: true, encoding: .utf8)
            return ON1Handoff(packageURL: package, photosURL: photos, count: items.count)
        } catch {
            try? files.removeItem(at: package)
            throw error
        }
    }

    private static func uniqueStem(for photo: PhotoRecord) -> String {
        let stem = photo.sourceURL.deletingPathExtension().lastPathComponent
        let digest = SHA256.hash(data: Data(photo.sourceURL.standardizedFileURL.path.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(stem)-\(digest)"
    }

    private static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

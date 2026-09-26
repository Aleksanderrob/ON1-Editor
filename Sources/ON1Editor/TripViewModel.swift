import AppKit
import Foundation

@MainActor
final class TripViewModel: ObservableObject {
    @Published var folderURL: URL?
    @Published var photos: [PhotoRecord] = []
    @Published var selectedID: String?
    @Published var preferences = TripPreferences()
    @Published var draftCorrection = Correction()
    @Published var isBusy = false
    @Published var message = "Choose a trip folder to begin."
    @Published var showError = false
    @Published var errorText = ""

    private var revision = 0
    var selected: PhotoRecord? { photos.first { $0.id == selectedID } }
    var referenceCount: Int { preferences.referenceIDs.count }
    var reviewCount: Int { photos.filter { $0.result?.status != .pass && $0.result != nil }.count }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open trip"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ folder: URL) {
        revision += 1
        let current = revision
        folderURL = folder
        photos = []
        selectedID = nil
        preferences = TripStore.load(for: folder)
        isBusy = true
        message = "Finding and analysing photos…"
        Task {
            do {
                let cache = try TripStore.cacheDirectory()
                let records = await Task.detached(priority: .userInitiated) {
                    PhotoLibrary.discover(in: folder).compactMap {
                        try? PhotoLibrary.analyze($0, relativeTo: folder, cacheDirectory: cache)
                    }
                }.value
                guard current == revision else { return }
                photos = records.sorted {
                    ($0.capturedAt ?? .distantFuture, $0.id) <
                        ($1.capturedAt ?? .distantFuture, $1.id)
                }
                selectedID = photos.first?.id
                loadDraft()
                isBusy = false
                message = photos.isEmpty ? "No readable photos found." :
                    "\(photos.count) photos ready. Choose one or more references."
                if !preferences.referenceIDs.isEmpty { rebuild() }
            } catch { report(error) }
        }
    }

    func select(_ id: String) {
        selectedID = id
        loadDraft()
    }

    func toggleReference(_ id: String) {
        if preferences.referenceIDs.contains(id) { preferences.referenceIDs.remove(id) }
        else { preferences.referenceIDs.insert(id) }
        persist()
        rebuild()
    }

    func applyCorrection() {
        guard let id = selectedID else { return }
        if draftCorrection.isZero { preferences.corrections.removeValue(forKey: id) }
        else { preferences.corrections[id] = draftCorrection }
        persist()
        rebuild()
    }

    func resetCorrection() {
        draftCorrection = Correction()
        applyCorrection()
    }

    func rebuild() {
        revision += 1
        let current = revision
        let inputs = photos
        let saved = preferences
        guard let profile = StyleEngine.profile(references: inputs.filter {
            saved.referenceIDs.contains($0.id)
        }) else {
            photos = photos.map { item in
                var copy = item
                copy.plan = nil; copy.result = nil; copy.editedPreviewURL = nil
                return copy
            }
            message = "Choose one or more references to generate edits."
            return
        }
        isBusy = true
        message = "Planning and rendering individual previews…"
        Task {
            do {
                let cache = try TripStore.cacheDirectory()
                let updated = await Task.detached(priority: .userInitiated) { () -> [PhotoRecord] in
                    let renderer = NativeRenderer()
                    return inputs.map { photo in
                        var item = photo
                        let otherPhotos = inputs.filter { $0.id != photo.id }
                        let otherCorrections = saved.corrections.filter { $0.key != photo.id }
                        let learned = StyleEngine.learnedPreference(for: photo.scene,
                            photos: otherPhotos, corrections: otherCorrections)
                        var plan = StyleEngine.plan(for: photo, profile: profile, preference: learned)
                        if let own = saved.corrections[photo.id], !saved.referenceIDs.contains(photo.id) {
                            plan.exposureEV = min(max(plan.exposureEV + own.exposureEV, -1.5), 1.5)
                            plan.contrast = min(max(plan.contrast + own.contrast, 0.7), 1.3)
                            plan.saturation = min(max(plan.saturation + own.saturation, 0.6), 1.4)
                            plan.warmth = min(max(plan.warmth + own.warmth, -0.5), 0.5)
                            plan.rationale.append("Your correction")
                        }
                        item.plan = plan
                        let edited = cache.appendingPathComponent("edited-\(current)-\(photo.previewURL.lastPathComponent)")
                        if let metrics = try? renderer.render(input: photo.previewURL, output: edited,
                                                              plan: plan, maxPixelSize: 1000) {
                            item.editedPreviewURL = edited
                            item.result = StyleEngine.evaluate(rendered: metrics,
                                target: profile.target(for: photo.scene), planConfidence: plan.confidence)
                        }
                        return item
                    }
                }.value
                guard current == revision else { return }
                photos = updated
                isBusy = false
                message = "\(updated.count) edits planned · \(reviewCount) to review"
            } catch { report(error) }
        }
    }

    func exportEdited() {
        guard folderURL != nil, photos.contains(where: { $0.plan != nil }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isBusy = true
        message = "Exporting edited JPEGs…"
        let items = photos
        Task {
            let summary = await Task.detached(priority: .userInitiated) { () -> (Int, Int, Int, Int, String?) in
                let renderer = NativeRenderer()
                var exported = 0, rawSkipped = 0, existingSkipped = 0, failures = 0
                var firstError: String?
                for photo in items {
                    guard let plan = photo.plan else { continue }
                    if PhotoLibrary.raw.contains(photo.sourceURL.pathExtension.lowercased()) {
                        rawSkipped += 1; continue
                    }
                    let components = photo.id.split(separator: "/").map(String.init)
                    let parent = components.dropLast().joined(separator: "/")
                    let stem = photo.sourceURL.deletingPathExtension().lastPathComponent
                    let outputFolder = parent.isEmpty ? destination : destination.appendingPathComponent(parent)
                    let output = outputFolder.appendingPathComponent(stem + "-" + photo.sourceURL.pathExtension.lowercased() + "-edited.jpg")
                    do {
                        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: output.path) {
                            existingSkipped += 1; continue
                        }
                        _ = try renderer.render(input: photo.sourceURL, output: output, plan: plan,
                                                maxPixelSize: nil)
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(plan).write(to: output.appendingPathExtension("json"), options: .atomic)
                        exported += 1
                    } catch {
                        failures += 1
                        if firstError == nil { firstError = error.localizedDescription }
                    }
                }
                return (exported, rawSkipped, existingSkipped, failures, firstError)
            }.value
            isBusy = false
            message = "Exported \(summary.0) JPEGs · \(summary.1) RAW skipped · \(summary.2) existing skipped · \(summary.3) errors"
            if summary.3 > 0, let error = summary.4 { reportMessage(error) }
        }
    }

    private func loadDraft() { draftCorrection = preferences.corrections[selectedID ?? ""] ?? Correction() }

    private func persist() {
        guard let folderURL else { return }
        do { try TripStore.save(preferences, for: folderURL) }
        catch { report(error) }
    }

    private func report(_ error: Error) { reportMessage(error.localizedDescription) }
    private func reportMessage(_ text: String) {
        isBusy = false
        errorText = text
        showError = true
        message = text
    }
}

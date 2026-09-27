import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class TripViewModel: ObservableObject {
    @Published var folderURL: URL?
    @Published var photos: [PhotoRecord] = []
    @Published var externalReferences: [PhotoRecord] = []
    @Published var unreadableCount = 0
    @Published var selectedID: String?
    @Published var preferences = TripPreferences()
    @Published var draftCorrection = Correction()
    @Published var isBusy = false
    @Published var lastHandoffURL: URL?
    @Published var lastON1RunURL: URL?
    @Published var message = "Choose a trip folder to begin."
    @Published var showError = false
    @Published var errorText = ""

    private var revision = 0
    var selected: PhotoRecord? { photos.first { $0.id == selectedID } }
    var referenceCount: Int { preferences.referenceIDs.count + externalReferences.count }
    var selectedCount: Int { preferences.selectedIDs?.count ?? photos.count }
    var reviewCount: Int { photos.filter { $0.result?.status != .pass && $0.result != nil }.count }

    func isSelected(_ id: String) -> Bool { preferences.selectedIDs?.contains(id) ?? true }

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
        externalReferences = []
        unreadableCount = 0
        selectedID = nil
        preferences = TripStore.load(for: folder)
        isBusy = true
        message = "Finding and analysing photos…"
        Task {
            do {
                let cache = try TripStore.cacheDirectory()
                let savedReferencePaths = preferences.externalReferencePaths
                let contents = await Task.detached(priority: .userInitiated) { () -> ([PhotoRecord], [PhotoRecord], Int) in
                    let files = PhotoLibrary.discover(in: folder)
                    let records = files.compactMap {
                        try? PhotoLibrary.analyze($0, relativeTo: folder, cacheDirectory: cache)
                    }
                    let references = savedReferencePaths.compactMap {
                        try? PhotoLibrary.analyzeExternalReference(URL(fileURLWithPath: $0), cacheDirectory: cache)
                    }
                    return (records, references, files.count - records.count)
                }.value
                guard current == revision else { return }
                photos = contents.0.sorted {
                    ($0.capturedAt ?? .distantFuture, $0.id) <
                        ($1.capturedAt ?? .distantFuture, $1.id)
                }
                externalReferences = contents.1
                unreadableCount = contents.2
                if preferences.selectedIDs == nil {
                    preferences.selectedIDs = Set(photos.map(\.id))
                    persist()
                } else {
                    preferences.selectedIDs?.formIntersection(Set(photos.map(\.id)))
                }
                selectedID = photos.first?.id
                loadDraft()
                isBusy = false
                message = photos.isEmpty ? "No readable photos found." :
                    "\(photos.count) photos ready. Choose one or more references."
                if unreadableCount > 0 { message += " \(unreadableCount) unreadable file(s) skipped." }
                if !preferences.referenceIDs.isEmpty || !externalReferences.isEmpty { rebuild() }
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

    func addReferenceJPEGs() {
        guard folderURL != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.jpeg]
        panel.prompt = "Add references"
        guard panel.runModal() == .OK else { return }
        do {
            let cache = try TripStore.cacheDirectory()
            let existing = Set(externalReferences.map { $0.sourceURL.standardizedFileURL.path })
            let added = panel.urls.filter { !existing.contains($0.standardizedFileURL.path) }
                .compactMap { try? PhotoLibrary.analyzeExternalReference($0, cacheDirectory: cache) }
            externalReferences.append(contentsOf: added)
            preferences.externalReferencePaths = externalReferences.map { $0.sourceURL.path }
            persist()
            rebuild()
        } catch { report(error) }
    }

    func removeExternalReference(_ id: String) {
        externalReferences.removeAll { $0.id == id }
        preferences.externalReferencePaths = externalReferences.map { $0.sourceURL.path }
        persist()
        rebuild()
    }

    func toggleSelected(_ id: String) {
        if isSelected(id) { preferences.selectedIDs?.remove(id) }
        else { preferences.selectedIDs?.insert(id) }
        persist()
        rebuild()
    }

    func selectAll() {
        preferences.selectedIDs = Set(photos.map(\.id))
        persist()
        rebuild()
    }

    func selectNone() {
        preferences.selectedIDs = []
        persist()
        rebuild()
    }

    func selectRAWOnly() {
        preferences.selectedIDs = Set(photos.filter {
            PhotoLibrary.raw.contains($0.sourceURL.pathExtension.lowercased())
        }.map(\.id))
        persist()
        rebuild()
    }

    func setExportOriginal(_ value: Bool) {
        preferences.exportOriginal = value
        persist()
    }

    func setExportLongEdge(_ value: Int) {
        preferences.exportLongEdge = value
        persist()
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
        } + externalReferences) else {
            photos = photos.map { item in
                var copy = item
                copy.plan = nil; copy.result = nil; copy.editedPreviewURL = nil
                return copy
            }
            message = "Choose trip references or add reference JPEGs to generate edits."
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
                        guard saved.selectedIDs?.contains(photo.id) ?? true else {
                            item.plan = nil
                            item.result = nil
                            item.editedPreviewURL = nil
                            return item
                        }
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
                message = "\(selectedCount) edits planned · \(reviewCount) to review"
            } catch { report(error) }
        }
    }

    func exportEdited() {
        guard folderURL != nil, photos.contains(where: { $0.plan != nil }) else { return }
        let longEdge = preferences.exportLongEdge
        let fullSize = preferences.exportOriginal
        if !fullSize && !(256...20000).contains(longEdge) {
            reportMessage("Choose a long edge between 256 and 20,000 pixels.")
            return
        }
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
            let summary = await Task.detached(priority: .userInitiated) { () -> (Int, Int, Int, String?) in
                let renderer = NativeRenderer()
                var exported = 0, existingSkipped = 0, failures = 0
                var firstError: String?
                for photo in items {
                    guard let plan = photo.plan else { continue }
                    let stem = photo.sourceURL.deletingPathExtension().lastPathComponent
                    let hash = SHA256.hash(data: Data(photo.id.utf8))
                        .prefix(4).map { String(format: "%02x", $0) }.joined()
                    let output = destination.appendingPathComponent(stem + "-" + photo.sourceURL.pathExtension.lowercased() + "-edited-" + hash + ".jpg")
                    do {
                        if FileManager.default.fileExists(atPath: output.path) {
                            existingSkipped += 1; continue
                        }
                        _ = try renderer.render(input: photo.sourceURL, output: output, plan: plan,
                                                maxPixelSize: fullSize ? nil : longEdge)
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(plan).write(to: output.appendingPathExtension("json"), options: .atomic)
                        exported += 1
                    } catch {
                        failures += 1
                        if firstError == nil { firstError = error.localizedDescription }
                    }
                }
                return (exported, existingSkipped, failures, firstError)
            }.value
            isBusy = false
            message = "Exported \(summary.0) JPEGs · \(summary.1) existing skipped · \(summary.2) errors"
            if summary.2 > 0, let error = summary.3 { reportMessage(error) }
        }
    }

    func prepareForON1() {
        guard let folderURL else { return }
        let selectedPhotos = photos.filter { isSelected($0.id) && $0.plan != nil }
        guard !selectedPhotos.isEmpty else {
            reportMessage("Choose references and photos to edit before preparing ON1.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Create ON1 workspace"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let tripPath = folderURL.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath != tripPath && !destinationPath.hasPrefix(tripPath + "/") else {
            reportMessage("Choose a location outside the trip folder to avoid duplicate photos in the trip.")
            return
        }
        let references = photos.filter { preferences.referenceIDs.contains($0.id) } + externalReferences
        let requestedSize = preferences.exportOriginal ? nil : preferences.exportLongEdge
        if let requestedSize, !(256...20000).contains(requestedSize) {
            reportMessage("Choose a long edge between 256 and 20,000 pixels.")
            return
        }
        isBusy = true
        message = "Preparing copies and individual looks for ON1…"
        Task {
            do {
                let handoff = try await Task.detached(priority: .userInitiated) {
                    try ON1Bridge.prepare(selected: selectedPhotos, references: references,
                        in: destination, exportLongEdge: requestedSize)
                }.value
                isBusy = false
                lastHandoffURL = handoff.packageURL
                NSWorkspace.shared.activateFileViewerSelecting([handoff.photosURL])
                if let application = ON1Bridge.installedApplication() {
                    let configuration = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([handoff.photosURL], withApplicationAt: application,
                                            configuration: configuration) { _, error in
                        Task { @MainActor in
                            if let error {
                                self.reportMessage("Workspace ready, but ON1 did not open: \(error.localizedDescription). Choose Browse Folder manually.")
                            } else {
                                self.message = "\(handoff.count) copies ready. In ON1, use Browse Folder for Photos to Edit."
                            }
                        }
                    }
                } else {
                    message = "ON1 workspace is ready, but ON1 Photo RAW 2026 was not found."
                }
            } catch { report(error) }
        }
    }

    func automateInON1() {
        guard let folderURL else { return }
        let selectedPhotos = photos.filter { isSelected($0.id) && $0.plan != nil }
        guard !selectedPhotos.isEmpty else {
            reportMessage("Choose JPEG references and photos to edit first.")
            return
        }
        let requestedSize = preferences.exportOriginal ? nil : preferences.exportLongEdge
        if let requestedSize, !(256...20000).contains(requestedSize) {
            reportMessage("Choose a long edge between 256 and 20,000 pixels.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export ON1 photos here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let tripPath = folderURL.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath != tripPath && !destinationPath.hasPrefix(tripPath + "/") else {
            reportMessage("Choose an export folder outside the trip to keep originals and exports separate.")
            return
        }
        isBusy = true
        message = "Preparing selected photo copies for ON1…"
        Task {
            do {
                let result = try await ON1Automation.run(selected: selectedPhotos,
                    destination: destination, longEdge: requestedSize) { progress in
                    Task { @MainActor in self.message = progress }
                }
                isBusy = false
                lastON1RunURL = result.runFolder
                message = "ON1 exported \(result.exportedCount) of \(selectedPhotos.count) selected photos"
                if result.failedCount > 0 {
                    reportMessage("ON1 exported \(result.exportedCount) photo(s). \(result.failedCount) stopped: \(result.items.first(where: { $0.error != nil })?.error ?? "Unknown error")")
                }
            } catch { report(error) }
        }
    }

    func showLastHandoff() {
        guard let lastHandoffURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastHandoffURL.appendingPathComponent("Photos to Edit")])
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

import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import ImageIO

struct ON1ControlValues: Equatable {
    let exposure: String
    let contrast: String
    let saturation: String
    let temperature: String

    init(_ plan: EditPlan) {
        exposure = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), plan.exposureEV)
        contrast = String(Int(((plan.contrast - 1) * 100).rounded()).clamped(to: -30...30))
        saturation = String(Int(((plan.saturation - 1) * 100).rounded()).clamped(to: -40...40))
        temperature = String(Int((plan.warmth * 60).rounded()).clamped(to: -30...30))
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

struct ON1AutomationResult {
    struct Item: Codable {
        let source: String
        let exported: String?
        let plan: EditPlan
        let error: String?
    }

    let items: [Item]
    let runFolder: URL
    var exportedCount: Int { items.filter { $0.exported != nil }.count }
    var failedCount: Int { items.filter { $0.error != nil }.count }
}

enum ON1AutomationError: LocalizedError {
    case accessibilityNeeded
    case on1Missing
    case on1DidNotLaunch
    case on1NotReady
    case ui(String)
    case sourceMissing(String)
    case exportMissing(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNeeded:
            "Allow ON1 Editor in System Settings → Privacy & Security → Device Control and Data Access (Accessibility on older macOS), then try again."
        case .on1Missing: "ON1 Photo RAW 2026 is not installed."
        case .on1DidNotLaunch: "ON1 Photo RAW did not start."
        case .on1NotReady: "ON1 Photo RAW did not become ready. Open ON1 and check that it responds, then try again."
        case .ui(let detail): "ON1's controls changed or did not respond: \(detail)"
        case .sourceMissing(let name): "Could not find \(name)."
        case .exportMissing(let name): "ON1 did not create \(name)."
        }
    }
}

enum ON1Automation {
    static func accessibilityReady(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func run(selected: [PhotoRecord], destination: URL, longEdge: Int?,
                    progress: @escaping @Sendable (String) -> Void) async throws -> ON1AutomationResult {
        guard let application = ON1Bridge.installedApplication() else { throw ON1AutomationError.on1Missing }
        guard accessibilityReady(prompt: true) else { throw ON1AutomationError.accessibilityNeeded }
        guard !selected.isEmpty else { throw ON1HandoffError.noSelectedPlans }

        let files = FileManager.default
        let store = try TripStore.appDirectory().appendingPathComponent("ON1 Runs", isDirectory: true)
        try files.createDirectory(at: store, withIntermediateDirectories: true)
        let runID = UUID().uuidString.prefix(8).lowercased()
        let runFolder = store.appendingPathComponent("Run \(Int(Date().timeIntervalSince1970)) \(runID)", isDirectory: true)
        try files.createDirectory(at: runFolder, withIntermediateDirectories: true)
        var staged: [(photo: PhotoRecord, input: URL, output: URL, plan: EditPlan)] = []
        for photo in selected {
            guard let plan = photo.plan else { continue }
            guard files.fileExists(atPath: photo.sourceURL.path) else {
                throw ON1AutomationError.sourceMissing(photo.sourceURL.lastPathComponent)
            }
            let digest = SHA256.hash(data: Data(photo.sourceURL.standardizedFileURL.path.utf8))
                .prefix(4).map { String(format: "%02x", $0) }.joined()
            let originalStem = String(photo.sourceURL.deletingPathExtension().lastPathComponent.prefix(150))
            let stem = "\(originalStem)-\(digest)-\(runID)"
            let input = runFolder.appendingPathComponent(stem + "." + photo.sourceURL.pathExtension.lowercased())
            let output = destination.appendingPathComponent(stem + ".jpg")
            try files.copyItem(at: photo.sourceURL, to: input)
            staged.append((photo, input, output, plan))
        }
        guard !staged.isEmpty else { throw ON1HandoffError.noSelectedPlans }

        let running: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: ON1AutomationError.on1DidNotLaunch) }
            }
        }
        progress("Connecting to ON1 Photo RAW…")
        return try await Task.detached(priority: .userInitiated) {
            let driver = ON1Accessibility(pid: running.processIdentifier)
            var items: [ON1AutomationResult.Item] = []
            for (index, entry) in staged.enumerated() {
                progress("ON1 editing \(index + 1) of \(staged.count): \(entry.photo.sourceURL.lastPathComponent)")
                do {
                    try driver.editSinglePhoto(entry.input)
                    try driver.apply(ON1ControlValues(entry.plan), filename: entry.input.lastPathComponent)
                    progress("ON1 exporting \(index + 1) of \(staged.count)…")
                    try driver.export(to: destination, longEdge: longEdge, expected: entry.output)
                    try driver.closeSinglePhoto()
                    items.append(.init(source: entry.photo.sourceURL.path,
                                       exported: entry.output.path, plan: entry.plan, error: nil))
                } catch {
                    let produced = files.fileExists(atPath: entry.output.path) ? entry.output.path : nil
                    items.append(.init(source: entry.photo.sourceURL.path, exported: produced,
                                       plan: entry.plan, error: error.localizedDescription))
                    // Stop when ON1's UI differs from the verified sequence; continuing could edit another photo.
                    break
                }
            }
            if items.count < staged.count {
                for entry in staged.dropFirst(items.count) {
                    items.append(.init(source: entry.photo.sourceURL.path, exported: nil,
                                       plan: entry.plan, error: "Not attempted after ON1 stopped."))
                }
            }
            let report = runFolder.appendingPathComponent("Run report.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: report, options: .atomic)
            return ON1AutomationResult(items: items, runFolder: runFolder)
        }.value
    }
}

private final class ON1Accessibility {
    private let app: AXUIElement
    private let running: NSRunningApplication?

    init(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        running = NSRunningApplication(processIdentifier: pid)
        AXUIElementSetMessagingTimeout(app, 4)
    }

    func editSinglePhoto(_ photo: URL) throws {
        running?.activate()
        do { try waitForWindow(excluding: ["Export", "Quick Export"], timeout: 60) }
        catch { throw ON1AutomationError.on1NotReady }
        try clickMenu("File", item: "Edit Single Photo...")
        try chooseFile(photo)
        try waitForWindow(containing: "Develop (\(photo.lastPathComponent)", timeout: 25)
    }

    func apply(_ values: ON1ControlValues, filename: String) throws {
        try waitForWindow(containing: "Develop (\(filename)", timeout: 12)
        if find(identifierSuffix: "tonePane.mBody.mPaneControls1.exposureSlider.widget.mDoubleLineEdit") == nil {
            try press(identifierSuffix: "tonePane.mHeader.mHeaderLabel")
        }
        try setField("exposureSlider.widget.mDoubleLineEdit", to: values.exposure)
        try setField("contrastSlider.widget.mIntLineEdit", to: values.contrast)
        try setField("saturationSlider.widget.mIntLineEdit", to: values.saturation)
        try setField("temperatureSlider.widget.mIntLineEdit", to: values.temperature)
        try press(identifierSuffix: "OnOneExportToolButton")
        try waitForWindow(containing: "Export - 1 Photo", timeout: 15)
    }

    func export(to folder: URL, longEdge: Int?, expected: URL) throws {
        let exportTitle = "Export - 1 Photo"
        try waitForWindow(containing: exportTitle, timeout: 15)
        let saveTo = try required("PLExportLocationPane.locationPane.mBody.locationWidget.widget_3.saveToWidget.mSaveToComboBox.mComboBox")
        let rendered: URL
        switch title(of: saveTo) {
        case "Other Folder":
            let destinationLabel = try required("PLExportLocationPane.locationPane.mBody.locationWidget.widget_3.pathChooseWidget.pathLabel")
            if (value(of: destinationLabel) as? String) != folder.path {
                try press(identifierSuffix: "PLExportLocationPane.locationPane.mBody.locationWidget.widget_3.pathChooseWidget.mChooseButton")
                try chooseFolder(folder)
                try waitForWindow(containing: exportTitle, timeout: 15)
            }
            let currentDestination = try required("PLExportLocationPane.locationPane.mBody.locationWidget.widget_3.pathChooseWidget.pathLabel")
            guard (value(of: currentDestination) as? String) == folder.path else {
                throw ON1AutomationError.ui("Export destination was not selected")
            }
            rendered = expected
        case "Desktop":
            // ON1's destination menu is not exposed through Accessibility on some builds.
            // Export under a unique run name, then move that JPEG into the selected folder.
            rendered = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
                .appendingPathComponent(expected.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: rendered.path) else {
                throw ON1AutomationError.ui("A temporary Desktop export already exists")
            }
        default:
            throw ON1AutomationError.ui("ON1's export location must be Desktop or Other Folder")
        }
        try selectMenuValue("PLExportFileTypePane.mPane0.mBody.mPaneControls0.fileTypeWidget.mFileTypeComboBox.mComboBox",
                            expected: "JPEG")
        let subfolder = try required("PLExportLocationPane.locationPane.mBody.locationWidget.subFolderWidget.subfolderCbox")
        if (value(of: subfolder) as? Int) == 1 { try click(subfolder) }
        try setResize(enabled: longEdge != nil)
        if let longEdge {
            try selectMenuValue("PLExportResizePane.mPane0.mBody.controls.primary.widget.mResizeType.mComboBox",
                                expected: "Long Edge")
            try setField("PLExportResizePane.mPane0.mBody.controls.primary.mStackedWidget.longEdgePage.widget_7.widget_16.widget_15.mLongEdgeEdit",
                         to: String(longEdge))
        }
        try deselectExportPreset()
        try press(identifierSuffix: "PLExportDlg2.bottomLayout.exportBtn")
        try waitForWindow(containing: "Develop (", timeout: 20)
        let deadline = Date().addingTimeInterval(90)
        var dimensions: (Int, Int)?
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: rendered.path),
               let source = CGImageSourceCreateWithURL(rendered as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                dimensions = (width, height)
                break
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard let dimensions,
              longEdge == nil || abs(max(dimensions.0, dimensions.1) - longEdge!) <= 1 else {
            throw ON1AutomationError.exportMissing(expected.lastPathComponent)
        }
        if rendered != expected {
            try FileManager.default.moveItem(at: rendered, to: expected)
        }
    }

    func closeSinglePhoto() throws {
        try press(identifierSuffix: "mCloseSaveButtonsWidget.mButtonClose")
        let dialog = try waitForWindow(containing: "", timeout: 8, exact: true)
        guard tree(dialog).contains(where: { (value(of: $0) as? String)?.contains("cancel editing") == true }) else {
            throw ON1AutomationError.ui("Unexpected close confirmation")
        }
        try press(identifierSuffix: "OnOneMessageBox.qt_msgbox_buttonbox.QPushButton", title: "OK")
        try waitForWindow(excluding: ["Develop", "Export", "Quick Export"], timeout: 15)
    }

    private func chooseFile(_ url: URL) throws {
        try waitForWindow(containing: "Open", timeout: 10)
        sendKey(5, flags: [.maskCommand, .maskShift]) // Command-Shift-G
        let path = try waitFor(identifierSuffix: "PathTextField", timeout: 8)
        try setValue(path, url.path)
        sendKey(36)
        _ = try waitFor(identifierSuffix: "OKButton", timeout: 8)
        try press(identifierSuffix: "OKButton")
    }

    private func chooseFolder(_ url: URL) throws {
        // ON1 labels this system picker "Choose the destination directory".
        // Its title differs from the picker used for opening a photo.
        _ = try waitFor(identifierSuffix: "OKButton", timeout: 10)
        sendKey(5, flags: [.maskCommand, .maskShift])
        let path = try waitFor(identifierSuffix: "PathTextField", timeout: 8)
        try setValue(path, url.path)
        sendKey(36)
        _ = try waitFor(identifierSuffix: "OKButton", timeout: 8)
        try press(identifierSuffix: "OKButton")
    }

    private func setResize(enabled: Bool) throws {
        let label = try required("PLExportDlg2.topLayout.optionsWidget.optionsScrollArea.qt_scrollarea_viewport.OnOnePanes.OnOnePane.mPaneHeader.mHeaderLabel",
                                 valueContains: "Resize")
        guard let rawParent = attribute(label, kAXParentAttribute as String) else {
            throw ON1AutomationError.ui("Resize control was not found")
        }
        let parent = rawParent as! AXUIElement
        guard let checkbox = children(parent).first(where: { role(of: $0) == kAXCheckBoxRole as String }) else {
            throw ON1AutomationError.ui("Resize control was not found")
        }
        let checked = (value(of: checkbox) as? Int) == 1
        if checked != enabled { try click(checkbox) }
    }

    private func selectMenuValue(_ identifier: String, expected: String) throws {
        let control = try required(identifier)
        if (value(of: control) as? String) == expected || title(of: control) == expected { return }
        try click(control)
        let option = try waitFor(title: expected, role: kAXMenuItemRole as String, timeout: 5)
        try click(option)
        let updated = try required(identifier)
        guard (value(of: updated) as? String) == expected || title(of: updated) == expected else {
            throw ON1AutomationError.ui("Could not select \(expected)")
        }
    }

    private func deselectExportPreset() throws {
        let marker = "PLExportPresetPanes.mPanes.OnOnePane.mPaneHeader.mHeaderContainer.mOnOffCheckBox"
        let dialog = try waitForWindow(containing: "Export - 1 Photo", timeout: 5)
        if let selected = tree(dialog).first(where: {
            (identifier(of: $0)?.contains(marker) ?? false) && (value(of: $0) as? Int) == 1
        }) {
            try click(selected)
        }
        let updated = try waitForWindow(containing: "Export - 1 Photo", timeout: 5)
        guard !tree(updated).contains(where: {
            (identifier(of: $0)?.contains(marker) ?? false) && (value(of: $0) as? Int) == 1
        }) else {
            throw ON1AutomationError.ui("An export preset is still selected")
        }
    }

    private func setField(_ identifier: String, to value: String) throws {
        let field = try required(identifier)
        try setValue(field, value)
        sendKey(36)
        let committed = try required(identifier)
        guard let actual = self.value(of: committed) as? String,
              Double(actual) == Double(value) else {
            throw ON1AutomationError.ui("Could not set \(identifier)")
        }
    }

    private func setValue(_ element: AXUIElement, _ text: String) throws {
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        guard error == .success else { throw ON1AutomationError.ui("Text control rejected a value (\(error.rawValue))") }
        let focus = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard focus == .success else {
            throw ON1AutomationError.ui("Text control could not receive keyboard focus (\(focus.rawValue))")
        }
    }

    private func clickMenu(_ name: String, item: String) throws {
        guard let rawMenuBar = attribute(app, kAXMenuBarAttribute as String) else {
            throw ON1AutomationError.ui("\(name) menu was not found")
        }
        let menuBar = rawMenuBar as! AXUIElement
        guard let menu = tree(menuBar).first(where: { title(of: $0) == name }) else {
            throw ON1AutomationError.ui("\(name) menu was not found")
        }
        try click(menu)
        let target = try waitFor(title: item, timeout: 6)
        try click(target)
    }

    private func press(identifierSuffix: String, title: String? = nil) throws {
        let item = try required(identifierSuffix, title: title)
        try click(item)
    }

    private func click(_ element: AXUIElement) throws {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        guard let rawPoint = attribute(element, kAXPositionAttribute as String),
              let rawSize = attribute(element, kAXSizeAttribute as String) else {
            throw ON1AutomationError.ui("A control could not be clicked")
        }
        let point = rawPoint as! AXValue
        let size = rawSize as! AXValue
        var origin = CGPoint.zero
        var bounds = CGSize.zero
        AXValueGetValue(point, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &bounds)
        let location = CGPoint(x: origin.x + bounds.width / 2, y: origin.y + bounds.height / 2)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: location,
                mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.12)
    }

    private func required(_ suffix: String, valueContains: String? = nil,
                          title: String? = nil) throws -> AXUIElement {
        guard let item = find(identifierSuffix: suffix, valueContains: valueContains, title: title) else {
            throw ON1AutomationError.ui("\(suffix) was not found")
        }
        return item
    }

    private func waitFor(identifierSuffix: String? = nil, title: String? = nil,
                         role: String? = nil,
                         timeout: TimeInterval) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let item = find(identifierSuffix: identifierSuffix, title: title, role: role) { return item }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ON1AutomationError.ui("Timed out waiting for \(identifierSuffix ?? title ?? "ON1")")
    }

    @discardableResult
    private func waitForWindow(containing text: String, timeout: TimeInterval,
                               exact: Bool = false) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = windows().first(where: {
                let name = title(of: $0) ?? ""
                return exact ? name == text : name.contains(text)
            }) { return window }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ON1AutomationError.ui("Timed out waiting for \(text) window")
    }

    @discardableResult
    private func waitForWindow(excluding words: [String], timeout: TimeInterval) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = windows().first(where: {
                let name = title(of: $0) ?? ""
                return !words.contains(where: name.contains)
            }) { return window }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ON1AutomationError.ui("ON1 did not return to its home window")
    }

    private func find(identifierSuffix: String? = nil, valueContains: String? = nil,
                      title: String? = nil, role: String? = nil) -> AXUIElement? {
        var roots = windows()
        if let rawMenuBar = attribute(app, kAXMenuBarAttribute as String) {
            roots.append(rawMenuBar as! AXUIElement)
        }
        for window in roots {
            if let item = tree(window).first(where: { element in
                if let identifierSuffix,
                   !(identifier(of: element)?.hasSuffix(identifierSuffix) ?? false) { return false }
                if let valueContains,
                   !((value(of: element) as? String)?.contains(valueContains) ?? false) { return false }
                if let title, self.title(of: element) != title { return false }
                if let role, self.role(of: element) != role { return false }
                return true
            }) { return item }
        }
        return nil
    }

    private func tree(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue = [root]
        var offset = 0
        while offset < queue.count && result.count < 1500 {
            let item = queue[offset]
            offset += 1
            result.append(item)
            queue.append(contentsOf: children(item))
        }
        return result
    }

    private func windows() -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var output: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &output) == .success ? output : nil
    }

    private func identifier(of element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute as String) as? String
    }
    private func title(of element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute as String) as? String
    }
    private func value(of element: AXUIElement) -> AnyObject? {
        attribute(element, kAXValueAttribute as String)
    }
    private func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute as String) as? String
    }
}

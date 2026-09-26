import Foundation

enum PhotoScene: String, Codable, CaseIterable, Sendable {
    case lowLight = "Low light"
    case indoor = "Mixed light"
    case daylight = "Daylight"

    static func classify(_ metrics: ImageMetrics) -> PhotoScene {
        if metrics.luminance < 0.24 { return .lowLight }
        if metrics.luminance > 0.45 { return .daylight }
        return .indoor
    }
}

struct ImageMetrics: Codable, Equatable, Sendable {
    var luminance: Double
    var contrast: Double
    var saturation: Double
    var warmth: Double
    var highlightClipping: Double
    var shadowClipping: Double
}

struct PhotoRecord: Identifiable, Sendable {
    let id: String // path relative to the selected trip folder
    let sourceURL: URL
    let previewURL: URL
    let capturedAt: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let metrics: ImageMetrics
    var scene: PhotoScene { PhotoScene.classify(metrics) }
    var plan: EditPlan?
    var result: ConsistencyResult?
    var editedPreviewURL: URL?
}

struct StyleProfile: Codable, Sendable {
    let referenceIDs: [String]
    let global: ImageMetrics
    let byScene: [PhotoScene: ImageMetrics]

    func target(for scene: PhotoScene) -> ImageMetrics { byScene[scene] ?? global }
}

struct EditPlan: Codable, Equatable, Sendable {
    // This vocabulary is independent of the rendering backend.
    var exposureEV: Double
    var contrast: Double
    var saturation: Double
    var warmth: Double
    var confidence: Double
    var rationale: [String]

    static let identity = EditPlan(exposureEV: 0, contrast: 1, saturation: 1,
                                   warmth: 0, confidence: 1, rationale: [])
}

enum ConsistencyStatus: String, Codable, Sendable {
    case pass = "In style"
    case uncertain = "Review"
    case outlier = "Outlier"
}

struct ConsistencyResult: Codable, Sendable {
    let status: ConsistencyStatus
    let confidence: Double
    let distance: Double
}

struct Correction: Codable, Sendable {
    var exposureEV: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var warmth: Double = 0
    var isZero: Bool {
        abs(exposureEV) < 0.001 && abs(contrast) < 0.001 &&
        abs(saturation) < 0.001 && abs(warmth) < 0.001
    }
}

struct TripPreferences: Codable, Sendable {
    var referenceIDs: Set<String> = []
    var corrections: [String: Correction] = [:]
}

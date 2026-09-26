import Foundation

enum StyleEngine {
    static func profile(references: [PhotoRecord]) -> StyleProfile? {
        guard !references.isEmpty else { return nil }
        var scenes: [PhotoScene: ImageMetrics] = [:]
        for scene in PhotoScene.allCases {
            let values = references.filter { $0.scene == scene }.map(\.metrics)
            if !values.isEmpty { scenes[scene] = median(values) }
        }
        return StyleProfile(referenceIDs: references.map(\.id).sorted(),
                            global: median(references.map(\.metrics)), byScene: scenes)
    }

    static func plan(for photo: PhotoRecord, profile: StyleProfile,
                     preference: Correction = Correction()) -> EditPlan {
        if profile.referenceIDs.contains(photo.id) { return .identity }
        let target = profile.target(for: photo.scene)
        let source = photo.metrics
        var rationale: [String] = []

        // Respect the broad lighting class when the available references are from another scene.
        let desiredLuminance: Double
        if profile.byScene[photo.scene] == nil {
            switch photo.scene {
            case .lowLight: desiredLuminance = min(target.luminance, 0.30)
            case .indoor: desiredLuminance = min(max(target.luminance, 0.27), 0.48)
            case .daylight: desiredLuminance = max(target.luminance, 0.40)
            }
        } else {
            desiredLuminance = target.luminance
        }
        let exposure = clamp(log2(max(desiredLuminance, 0.03) /
                                  max(source.luminance, 0.03)) * 0.65, -1.0, 1.0)
        if abs(exposure) > 0.08 { rationale.append(exposure > 0 ? "Lift exposure" : "Reduce exposure") }

        let saturation = clamp(1 + (target.saturation - source.saturation) * 0.9, 0.72, 1.28)
        if abs(saturation - 1) > 0.03 { rationale.append(saturation > 1 ? "Add colour" : "Restrain colour") }

        let contrast = clamp(1 + (target.contrast - source.contrast) * 0.8, 0.82, 1.18)
        if abs(contrast - 1) > 0.03 { rationale.append(contrast > 1 ? "Add contrast" : "Soften contrast") }

        let warmth = clamp((target.warmth - source.warmth) * 1.7, -0.35, 0.35)
        if abs(warmth) > 0.025 { rationale.append(warmth > 0 ? "Warm colour" : "Cool colour") }

        let contextPenalty = profile.byScene[photo.scene] == nil ? 0.13 : 0
        let clippingPenalty = min(0.18, (source.highlightClipping + source.shadowClipping) * 0.4)
        let confidence = clamp(0.88 - contextPenalty - clippingPenalty, 0.45, 0.95)
        return EditPlan(exposureEV: clamp(exposure + preference.exposureEV, -1.5, 1.5),
                        contrast: clamp(contrast + preference.contrast, 0.7, 1.3),
                        saturation: clamp(saturation + preference.saturation, 0.6, 1.4),
                        warmth: clamp(warmth + preference.warmth, -0.5, 0.5),
                        confidence: confidence, rationale: rationale)
    }

    static func learnedPreference(for scene: PhotoScene, photos: [PhotoRecord],
                                  corrections: [String: Correction]) -> Correction {
        let values = photos.filter { $0.scene == scene }.compactMap { corrections[$0.id] }
        guard !values.isEmpty else { return Correction() }
        // A partial average prevents one correction from dominating every later image.
        let weight = min(0.65, Double(values.count) / (Double(values.count) + 3))
        let n = Double(values.count)
        return Correction(exposureEV: values.map(\.exposureEV).reduce(0, +) / n * weight,
                          contrast: values.map(\.contrast).reduce(0, +) / n * weight,
                          saturation: values.map(\.saturation).reduce(0, +) / n * weight,
                          warmth: values.map(\.warmth).reduce(0, +) / n * weight)
    }

    static func evaluate(rendered: ImageMetrics, target: ImageMetrics,
                         planConfidence: Double) -> ConsistencyResult {
        let distance = abs(rendered.luminance - target.luminance) * 1.6 +
            abs(rendered.contrast - target.contrast) * 1.1 +
            abs(rendered.saturation - target.saturation) * 1.2 +
            abs(rendered.warmth - target.warmth) * 1.0
        let confidence = clamp(planConfidence - distance * 0.75, 0, 1)
        let status: ConsistencyStatus = distance > 0.28 ? .outlier :
            (distance > 0.16 || confidence < 0.67 ? .uncertain : .pass)
        return ConsistencyResult(status: status, confidence: confidence, distance: distance)
    }

    private static func median(_ values: [ImageMetrics]) -> ImageMetrics {
        func m(_ key: KeyPath<ImageMetrics, Double>) -> Double {
            let sorted = values.map { $0[keyPath: key] }.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        return ImageMetrics(luminance: m(\.luminance), contrast: m(\.contrast),
                            saturation: m(\.saturation), warmth: m(\.warmth),
                            highlightClipping: m(\.highlightClipping),
                            shadowClipping: m(\.shadowClipping))
    }

    private static func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double {
        min(max(x, low), high)
    }
}

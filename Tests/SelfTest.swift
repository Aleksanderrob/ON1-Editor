import AppKit
import ImageIO
import Foundation
import UniformTypeIdentifiers

@main
struct SelfTest {
    static func main() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "SelfTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func metrics(_ luminance: Double) -> ImageMetrics {
            ImageMetrics(luminance: luminance, contrast: 0.18, saturation: 0.25,
                         warmth: 0.5, highlightClipping: 0, shadowClipping: 0)
        }
        func photo(_ id: String, _ m: ImageMetrics) -> PhotoRecord {
            PhotoRecord(id: id, sourceURL: URL(fileURLWithPath: "/\(id).jpg"),
                        previewURL: URL(fileURLWithPath: "/\(id)-preview.jpg"),
                        capturedAt: nil, pixelWidth: 100, pixelHeight: 100,
                        metrics: m, plan: nil, result: nil, editedPreviewURL: nil)
        }
        let reference = photo("reference", metrics(0.55))
        let profile = try XCTUnwrapStyle(StyleEngine.profile(references: [reference]))
        let dim = StyleEngine.plan(for: photo("dim", metrics(0.28)), profile: profile)
        let bright = StyleEngine.plan(for: photo("bright", metrics(0.75)), profile: profile)
        let night = StyleEngine.plan(for: photo("night", metrics(0.12)), profile: profile)
        try expect(dim.exposureEV > 0 && bright.exposureEV < 0, "Image-specific exposure directions")
        try expect(night.exposureEV < 1, "Low-light scene is not forced into daylight")
        try expect(StyleEngine.plan(for: reference, profile: profile) == .identity,
                   "Reference image remains unchanged")

        let preference = StyleEngine.learnedPreference(for: .indoor,
            photos: [photo("a", metrics(0.3))],
            corrections: ["a": Correction(exposureEV: -0.5)])
        try expect(preference.exposureEV < 0 && preference.exposureEV > -0.5,
                   "Corrections influence later plans conservatively")
        try expect(StyleEngine.evaluate(rendered: metrics(0.1), target: metrics(0.6),
                    planConfidence: 0.85).status == .outlier, "Outliers are surfaced")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("gray.png")
        let output = temp.appendingPathComponent("edited.jpg")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedWhite: 0.25, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = context.makeImage()!
        let colourContext = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        colourContext.setFillColor(NSColor.red.cgColor)
        colourContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        try expect(ImageAnalyzer.measure(colourContext.makeImage()!).warmth > 0.7,
                   "Channel order preserves red and blue")
        let destination = CGImageDestinationCreateWithURL(input as CFURL,
            UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "Fixture image is written")
        let before = ImageAnalyzer.measure(image)
        let after = try NativeRenderer().render(input: input, output: output,
            plan: EditPlan(exposureEV: 0.5, contrast: 1, saturation: 1,
                           warmth: 0, confidence: 1, rationale: []), maxPixelSize: nil)
        try expect(after.luminance > before.luminance + 0.05,
                   "Native renderer brightens the exported image")
        try expect(FileManager.default.fileExists(atPath: output.path), "Export is present")
        print("Self-test passed: planning, learning, evaluation, and JPEG rendering")
    }

    private static func XCTUnwrapStyle<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "SelfTest", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not create style profile"]) }
        return value
    }
}

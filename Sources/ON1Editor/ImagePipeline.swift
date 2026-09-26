import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum ImagePipelineError: LocalizedError {
    case unreadable(URL)
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Could not read \(url.lastPathComponent)."
        case .cannotWrite(let url): return "Could not write \(url.lastPathComponent)."
        }
    }
}

enum PhotoLibrary {
    static let supported = Set(["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
                                "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf"])
    static let raw = Set(["dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf"])

    static func discover(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { supported.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func analyze(_ url: URL, relativeTo folder: URL, cacheDirectory: URL) throws -> PhotoRecord {
        let relative = String(url.path.dropFirst(folder.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return try analyze(url, id: relative, cacheDirectory: cacheDirectory)
    }

    static func analyzeExternalReference(_ url: URL, cacheDirectory: URL) throws -> PhotoRecord {
        try analyze(url, id: "external:" + url.standardizedFileURL.path, cacheDirectory: cacheDirectory)
    }

    private static func analyze(_ url: URL, id: String, cacheDirectory: URL) throws -> PhotoRecord {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        guard let source, let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000
        ] as CFDictionary) else { throw ImagePipelineError.unreadable(url) }

        let attributes = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let dimensions = (attributes[kCGImagePropertyPixelWidth] as? Int ?? thumbnail.width,
                          attributes[kCGImagePropertyPixelHeight] as? Int ?? thumbnail.height)
        let exif = attributes[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let captured = dateString.flatMap(formatter.date(from:)) ?? values?.contentModificationDate

        let cacheKey = "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let fingerprint = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let previewURL = cacheDirectory.appendingPathComponent("original-\(fingerprint).jpg")
        if !FileManager.default.fileExists(atPath: previewURL.path) {
            try JPEGWriter.write(thumbnail, to: previewURL, quality: 0.84)
        }
        return PhotoRecord(id: id, sourceURL: url, previewURL: previewURL,
                           capturedAt: captured, pixelWidth: dimensions.0,
                           pixelHeight: dimensions.1, metrics: ImageAnalyzer.measure(thumbnail),
                           plan: nil, result: nil, editedPreviewURL: nil)
    }
}

enum ImageAnalyzer {
    static func measure(_ image: CGImage) -> ImageMetrics {
        let scale = min(1.0, 256.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            return ImageMetrics(luminance: 0, contrast: 0, saturation: 0, warmth: 0,
                                highlightClipping: 0, shadowClipping: 0)
        }
        var luminance = 0.0, squares = 0.0, saturation = 0.0, warmth = 0.0
        var highlights = 0.0, shadows = 0.0, count = 0.0
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[pixel + 3]) / 255
            if alpha < 0.1 { continue }
            let r = min(Double(pixels[pixel]) / 255 / alpha, 1)
            let g = min(Double(pixels[pixel + 1]) / 255 / alpha, 1)
            let b = min(Double(pixels[pixel + 2]) / 255 / alpha, 1)
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luminance += l; squares += l * l
            saturation += max(r, g, b) - min(r, g, b)
            warmth += (r - b) * 0.5 + 0.5
            if l > 0.96 { highlights += 1 }
            if l < 0.05 { shadows += 1 }
            count += 1
        }
        guard count > 0 else {
            return ImageMetrics(luminance: 0, contrast: 0, saturation: 0, warmth: 0,
                                highlightClipping: 0, shadowClipping: 0)
        }
        let mean = luminance / count
        return ImageMetrics(luminance: mean,
                            contrast: sqrt(max(0, squares / count - mean * mean)),
                            saturation: saturation / count, warmth: warmth / count,
                            highlightClipping: highlights / count, shadowClipping: shadows / count)
    }
}

protocol RendererAdapter {
    func render(input: URL, output: URL, plan: EditPlan, maxPixelSize: Int?) throws -> ImageMetrics
}

struct NativeRenderer: RendererAdapter {
    func render(input: URL, output: URL, plan: EditPlan, maxPixelSize: Int? = nil) throws -> ImageMetrics {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw ImagePipelineError.unreadable(input)
        }
        let original: CGImage?
        if let maxPixelSize {
            original = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ] as CFDictionary)
        } else {
            let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 2000
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 2000
            original = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
            ] as CFDictionary)
        }
        guard let original else { throw ImagePipelineError.unreadable(input) }
        if PhotoLibrary.raw.contains(input.pathExtension.lowercased()) {
            let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            let nativeWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let nativeHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            let nativeLongEdge = max(nativeWidth, nativeHeight)
            let expectedLongEdge = min(nativeLongEdge, maxPixelSize ?? nativeLongEdge)
            guard expectedLongEdge > 0,
                  Double(max(original.width, original.height)) >= Double(expectedLongEdge) * 0.9 else {
                throw ImagePipelineError.unreadable(input)
            }
        }
        let rendered = try PixelRenderer.apply(plan, to: original, source: input)
        try JPEGWriter.write(rendered, to: output, quality: 0.91)
        return ImageAnalyzer.measure(rendered)
    }
}

private enum PixelRenderer {
    static func apply(_ plan: EditPlan, to image: CGImage, source: URL) throws -> CGImage {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colourSpace,
                bitmapInfo: bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImagePipelineError.unreadable(source) }
        let exposure = pow(2, plan.exposureEV)
        let redGain = 1 + plan.warmth * 0.28
        let blueGain = 1 - plan.warmth * 0.28
        func clip(_ value: Double) -> Double { min(max(value, 0), 1) }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            if alpha < 0.001 { continue }
            var r = min(Double(pixels[offset]) / 255 / alpha, 1) * exposure
            var g = min(Double(pixels[offset + 1]) / 255 / alpha, 1) * exposure
            var b = min(Double(pixels[offset + 2]) / 255 / alpha, 1) * exposure
            r = (r - 0.5) * plan.contrast + 0.5
            g = (g - 0.5) * plan.contrast + 0.5
            b = (b - 0.5) * plan.contrast + 0.5
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r = clip((luma + (r - luma) * plan.saturation) * redGain)
            g = clip(luma + (g - luma) * plan.saturation)
            b = clip((luma + (b - luma) * plan.saturation) * blueGain)
            pixels[offset] = UInt8((r * alpha * 255).rounded())
            pixels[offset + 1] = UInt8((g * alpha * 255).rounded())
            pixels[offset + 2] = UInt8((b * alpha * 255).rounded())
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let rendered = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colourSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ImagePipelineError.unreadable(source)
        }
        return rendered
    }
}

private enum JPEGWriter {
    static func write(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImagePipelineError.cannotWrite(url)
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImagePipelineError.cannotWrite(url) }
    }
}

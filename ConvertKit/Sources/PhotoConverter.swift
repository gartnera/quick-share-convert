import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Output image format.
public enum PhotoFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case jpeg, heic

    public var id: String { rawValue }
    public var label: String { self == .jpeg ? "JPEG" : "HEIC" }
    public var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
    public var utType: UTType { self == .jpeg ? .jpeg : .heic }

    /// Whether ImageIO on this device can write the format (HEIC encoding needs
    /// hardware support; JPEG is always there).
    public var isEncodable: Bool {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return ids.contains(utType.identifier)
    }
}

/// Output size cap, by the photo's **long edge**. Photos keep their own aspect;
/// this only downscales.
public enum PhotoSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case original
    case large   // 4096
    case medium  // 2048
    case small   // 1080

    public var id: String { rawValue }

    /// Long-edge cap in pixels, or nil to keep the source size.
    public var maxLongEdge: Int? {
        switch self {
        case .original: return nil
        case .large: return 4096
        case .medium: return 2048
        case .small: return 1080
        }
    }

    public var label: String {
        switch self {
        case .original: return "Original"
        case .large: return "4K"
        case .medium: return "2K"
        case .small: return "1080"
        }
    }

    /// Used in the output file name.
    public var nameTag: String { maxLongEdge.map { "\($0)px" } ?? "full" }
}

/// Lossy compression quality (ImageIO's 0...1 scale).
public enum PhotoQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case high, medium, low

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var value: Double {
        switch self {
        case .high: return 0.85
        case .medium: return 0.7
        case .low: return 0.5
        }
    }
}

public struct PhotoOptions: Codable, Hashable, Sendable {
    public var format: PhotoFormat
    public var size: PhotoSize
    public var quality: PhotoQuality

    public init(format: PhotoFormat = .jpeg, size: PhotoSize = .original, quality: PhotoQuality = .high) {
        self.format = format
        self.size = size
        self.quality = quality
    }
}

/// What we know about a shared photo, used to gate size options.
public struct PhotoInfo: Equatable, Sendable {
    /// Orientation-corrected pixel size.
    public let orientedSize: CGSize
    /// UTI of the source container (e.g. `public.heic`), if known.
    public let typeIdentifier: String?

    public init(orientedSize: CGSize, typeIdentifier: String?) {
        self.orientedSize = orientedSize
        self.typeIdentifier = typeIdentifier
    }

    public var longEdge: Int { Int(max(orientedSize.width, orientedSize.height)) }

    /// Short format name for display, e.g. "HEIC".
    public var formatName: String? {
        typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension?.uppercased() }
    }

    /// Size caps that would actually shrink the photo (plus Original). A cap at
    /// or above the source's long edge would be the same as Original.
    public func availableSizes() -> [PhotoSize] {
        PhotoSize.allCases.filter { size in
            guard let cap = size.maxLongEdge else { return true }
            return cap < longEdge
        }
    }
}

/// Re-encodes a photo, keeping its aspect: optional downscale, orientation baked
/// into the pixels, HDR/gain maps dropped (SDR, 8-bit). Metadata (EXIF, GPS,
/// IPTC) passes through.
public final class PhotoConverter {
    public init() {}

    public static func loadSourceInfo(url: URL) throws -> PhotoInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.unreadableImage
        }
        return try sourceInfo(src)
    }

    private static func sourceInfo(_ src: CGImageSource) throws -> PhotoInfo {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ConversionError.unreadableImage
        }
        // EXIF orientations 5...8 are rotated 90°, so width and height swap.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let size = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        return PhotoInfo(orientedSize: size, typeIdentifier: CGImageSourceGetType(src) as String?)
    }

    public func convert(sourceURL: URL, options: PhotoOptions, outputURL: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)
        guard options.format.isEncodable else {
            throw ConversionError.encoderUnavailable(options.format.label)
        }
        guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw ConversionError.unreadableImage
        }
        let info = try Self.sourceInfo(src)
        let longEdge = min(options.size.maxLongEdge ?? info.longEdge, info.longEdge)

        // The thumbnail path applies EXIF orientation and downsamples during
        // decode (cheap on memory for 48MP sources); DecodeToSDR drops HDR.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(src, 0, decodeOptions as CFDictionary) else {
            throw ConversionError.unreadableImage
        }
        let image = try Self.flattenToSDR(decoded)

        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL, options.format.utType.identifier as CFString, 1, nil
        ) else {
            throw ConversionError.encoderUnavailable(options.format.label)
        }
        let sourceProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        var props = Self.passthroughMetadata(sourceProps, width: image.width, height: image.height)
        props[kCGImageDestinationLossyCompressionQuality] = options.quality.value
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.writerFailed("could not encode \(options.format.label)")
        }
        return outputURL
    }

    /// The source's EXIF/TIFF/GPS/IPTC metadata, adjusted for the new pixels:
    /// orientation reset to "up" (it's baked in) and EXIF dimensions updated.
    /// Apple's maker note is dropped — it carries the HDR gain-map hints, and
    /// the gain map itself isn't carried over.
    static func passthroughMetadata(_ source: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        var out: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let dict = source[key] { out[key] = dict }
        }
        if var tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            out[kCGImagePropertyExifDictionary] = exif
        }
        return out
    }

    /// Redraws into an 8-bit RGB context: keeps an SDR wide-gamut space like
    /// Display P3, but falls back to sRGB for HDR/extended-range or non-RGB
    /// sources. Transparency is flattened onto white (JPEG has no alpha).
    static func flattenToSDR(_ image: CGImage) throws -> CGImage {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { cs -> CGColorSpace? in
            cs.model == .rgb && !CGColorSpaceUsesExtendedRange(cs) && !CGColorSpaceUsesITUR_2100TF(cs) ? cs : nil
        } ?? srgb
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.writerFailed("could not allocate image buffer")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(colorSpace: srgb, components: [1, 1, 1, 1])!)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else {
            throw ConversionError.writerFailed("could not render image")
        }
        return out
    }
}

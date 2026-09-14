import CoreGraphics
import Foundation

/// Output resolution tier, expressed by the frame's **short edge** in pixels.
/// (1080p landscape = 1080 tall; a 9:16 vertical at "1080" = 1080 wide.)
public enum TargetResolution: Int, CaseIterable, Codable, Sendable, Identifiable {
    case fhd = 1080   // "1080p"
    case qhd = 1440   // "2K"
    case uhd = 2160   // "4K"

    public var id: Int { rawValue }
    public var shortEdge: Int { rawValue }
    public var label: String {
        switch self {
        case .fhd: return "1080p"
        case .qhd: return "2K"
        case .uhd: return "4K"
        }
    }
}

/// Output frame-rate tier.
public enum TargetFrameRate: Int, CaseIterable, Codable, Sendable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    public var id: Int { rawValue }
    public var label: String { "\(rawValue)" }
}

/// Recommended average H.264 bitrate for a resolution + frame-rate combination.
/// Presets are mostly about resolution and target bitrate, so this is the single
/// source of truth for bitrate; tune per platform later if needed.
public enum Bitrate {
    public static func recommended(resolution: TargetResolution, frameRate: TargetFrameRate) -> Int {
        let base: Int
        switch resolution {
        case .fhd: base = 8_000_000
        case .qhd: base = 16_000_000
        case .uhd: base = 40_000_000
        }
        // ~1.5x for 60fps.
        return frameRate == .fps60 ? base * 3 / 2 : base
    }

    /// The bitrate to actually encode with: the recommendation, but never higher
    /// than the source's data rate (no point inflating a low-bitrate clip).
    public static func forOutput(resolution: TargetResolution, frameRate: TargetFrameRate,
                                 sourceDataRate: Float) -> Int {
        let rec = recommended(resolution: resolution, frameRate: frameRate)
        return sourceDataRate > 0 ? min(rec, Int(sourceDataRate)) : rec
    }

    public static let audio = 128_000
}

/// What we know about the shared source, used to gate which target options are
/// offerable (never upscale, never invent frames).
public struct SourceInfo: Equatable, Sendable {
    /// Orientation-corrected display size (so width/height match what's shown).
    public let orientedSize: CGSize
    public let nominalFrameRate: Float

    public init(orientedSize: CGSize, nominalFrameRate: Float) {
        self.orientedSize = orientedSize
        self.nominalFrameRate = nominalFrameRate
    }

    /// Resolutions that don't require upscaling for `preset`. Always includes at
    /// least 1080p (the converter clamps to the source, so "1080p" means
    /// "up to 1080p" and never upscales).
    public func availableResolutions(for preset: Preset) -> [TargetResolution] {
        let ok = TargetResolution.allCases.filter { res in
            !VideoLayout.upscales(
                naturalSize: orientedSize,
                preferredTransform: .identity,
                targetSize: preset.outputSize(for: res),
                framing: preset.framing
            )
        }
        return ok.contains(.fhd) ? ok : [.fhd]
    }

    /// 60fps is only offered when the source actually has the frames for it.
    public var supports60fps: Bool { nominalFrameRate >= 50 }

    public func availableFrameRates() -> [TargetFrameRate] {
        supports60fps ? [.fps30, .fps60] : [.fps30]
    }
}

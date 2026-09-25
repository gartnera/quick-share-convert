import CoreGraphics
import Foundation

/// Output resolution tier, expressed by the frame's **short edge** in pixels.
/// (1080p landscape = 1080 tall; a 9:16 vertical at "1080" = 1080 wide.)
public enum TargetResolution: Int, CaseIterable, Codable, Sendable, Identifiable {
    case hd = 720     // "720p"
    case fhd = 1080   // "1080p"
    case qhd = 1440   // "2K"
    case uhd = 2160   // "4K"

    public var id: Int { rawValue }
    public var shortEdge: Int { rawValue }
    public var label: String {
        switch self {
        case .hd: return "720p"
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

/// Recommended average H.264 bitrate. The table is keyed by resolution tier and
/// frame rate for the tier's 16:9 reference frame (1280×720, 1920×1080,
/// 2560×1440, 3840×2160); the actual encode bitrate is scaled to the pixel area the output
/// frame really has, so a 1080×1080 square or a no-upscale-clamped small frame
/// isn't handed a 1920×1080 budget.
public enum Bitrate {
    /// Table rate for a tier's 16:9 reference frame.
    public static func recommended(resolution: TargetResolution, frameRate: TargetFrameRate) -> Int {
        let base: Int
        switch resolution {
        case .hd:  base = 4_000_000
        case .fhd: base = 8_000_000
        case .qhd: base = 16_000_000
        case .uhd: base = 40_000_000
        }
        // ~1.5x for 60fps.
        return frameRate == .fps60 ? base * 3 / 2 : base
    }

    /// Pixel area of the tier's 16:9 reference frame.
    static func referenceArea(_ resolution: TargetResolution) -> Double {
        let short = Double(resolution.shortEdge)
        return short * (short * 16 / 9)
    }

    /// Table rate scaled by how much of the reference area `renderSize` covers.
    public static func recommended(renderSize: CGSize, resolution: TargetResolution,
                                   frameRate: TargetFrameRate) -> Int {
        let area = Double(renderSize.width * renderSize.height)
        guard area > 0 else { return recommended(resolution: resolution, frameRate: frameRate) }
        let ratio = min(area / referenceArea(resolution), 1)
        let scaled = Double(recommended(resolution: resolution, frameRate: frameRate)) * ratio
        return max(minimum, Int(scaled.rounded()))
    }

    /// Never encode below this, however small the frame.
    public static let minimum = 500_000

    /// H.264 needs roughly this much more bitrate than HEVC for equal quality, so
    /// an HEVC source's data rate is inflated by it before it caps the output.
    public static let hevcToH264Factor = 1.5

    /// The bitrate to actually encode with: the area-scaled recommendation, but
    /// never higher than what the source can justify (no point inflating a
    /// low-bitrate clip). `sourceIsHEVC` widens the cap because the same visual
    /// quality costs more bits in H.264 than in HEVC.
    public static func forOutput(renderSize: CGSize, resolution: TargetResolution, frameRate: TargetFrameRate,
                                 sourceDataRate: Float, sourceIsHEVC: Bool) -> Int {
        let rec = recommended(renderSize: renderSize, resolution: resolution, frameRate: frameRate)
        guard sourceDataRate > 0 else { return rec }
        let cap = Double(sourceDataRate) * (sourceIsHEVC ? hevcToH264Factor : 1)
        return max(minimum, min(rec, Int(cap)))
    }

    public static let audio = 128_000

    /// Output AAC sample rate: keep the source's if it's a standard delivery rate
    /// (avoids a needless resample of 48 kHz camera audio down to 44.1), else 48 kHz.
    public static func audioSampleRate(source: Double) -> Int {
        let rate = Int(source.rounded())
        return [44_100, 48_000].contains(rate) ? rate : 48_000
    }

    /// Output channel count: stereo, or mono when the source is mono.
    public static func audioChannels(source: Int) -> Int {
        source >= 2 ? 2 : 1
    }
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

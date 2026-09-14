import CoreGraphics
import Foundation

/// How a source frame is mapped into the preset's target frame when the aspect
/// ratios don't match.
public enum Framing: String, Codable, Sendable {
    /// Scale to fit inside the target box, preserving aspect ratio. Never crops.
    /// The output size follows the source aspect (bounded by the target box).
    case fit
    /// Scale-and-crop so the output exactly fills the target frame. May trim edges.
    case fill
}

/// A conversion preset: the complete recipe for one output.
///
/// Presets are intentionally plain data so they can be shown in a picker,
/// serialized into a job, and (later) edited by the user.
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    /// SF Symbol used in the picker.
    public let symbol: String

    /// Target frame in pixels. For `.fit` this is the bounding box; for `.fill`
    /// it's the exact output size.
    public let width: Int
    public let height: Int
    public let framing: Framing

    /// Cap the output frame rate to this value (source fps is kept if lower).
    public let maxFrameRate: Int
    /// Target average video bitrate in bits/sec.
    public let videoBitrate: Int
    /// Target audio bitrate in bits/sec.
    public let audioBitrate: Int

    public var targetSize: CGSize { CGSize(width: width, height: height) }

    public init(
        id: String,
        name: String,
        subtitle: String,
        symbol: String,
        width: Int,
        height: Int,
        framing: Framing,
        maxFrameRate: Int = 30,
        videoBitrate: Int,
        audioBitrate: Int = 128_000
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.symbol = symbol
        self.width = width
        self.height = height
        self.framing = framing
        self.maxFrameRate = maxFrameRate
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
    }
}

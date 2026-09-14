import CoreGraphics
import Foundation

/// How a source frame is mapped into the preset's target frame when the aspect
/// ratios don't match.
public enum Framing: String, Codable, Sendable {
    /// Scale to fit inside the target box, preserving aspect ratio. Never crops.
    case fit
    /// Scale-and-crop so the output fills the target frame. May trim edges.
    case fill
}

/// A conversion preset: the output **aspect ratio** and framing rule. The actual
/// pixel size comes from the user-chosen `TargetResolution`, and the bitrate from
/// resolution + frame rate (see `Bitrate`). So a preset is "shape", not "size".
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// SF Symbol used in the picker.
    public let symbol: String

    /// Output aspect ratio in orientation (e.g. 9×16 portrait, 16×9 landscape).
    public let aspectWidth: Int
    public let aspectHeight: Int
    public let framing: Framing

    public init(id: String, name: String, symbol: String,
                aspectWidth: Int, aspectHeight: Int, framing: Framing) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
        self.framing = framing
    }

    /// e.g. "9:16".
    public var aspectLabel: String { "\(aspectWidth):\(aspectHeight)" }

    /// Short human description of shape + framing, e.g. "9:16 · cropped".
    public var subtitle: String {
        "\(aspectLabel) · \(framing == .fill ? "cropped" : "fit")"
    }

    /// The output pixel size for a resolution tier: the tier's value is the
    /// **short edge**, the long edge follows the aspect ratio.
    public func outputSize(for resolution: TargetResolution) -> CGSize {
        let short = CGFloat(resolution.shortEdge)
        let aw = CGFloat(aspectWidth), ah = CGFloat(aspectHeight)
        if aw == ah { return CGSize(width: short, height: short) }
        if aw < ah { // portrait: width is the short edge
            return CGSize(width: short, height: (short * ah / aw).rounded())
        } else {      // landscape: height is the short edge
            return CGSize(width: (short * aw / ah).rounded(), height: short)
        }
    }
}

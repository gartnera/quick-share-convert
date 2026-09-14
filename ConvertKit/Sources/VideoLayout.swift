import CoreGraphics
import Foundation

/// The geometry of one conversion: the output render size and the affine
/// transform that maps the (oriented) source into that frame.
///
/// This is deliberately a pure value type computed by a pure function so the
/// fit/fill/orientation math can be unit-tested without touching AVFoundation
/// or a real video file.
public struct VideoLayout: Equatable, Sendable {
    public let renderSize: CGSize
    public let transform: CGAffineTransform

    public init(renderSize: CGSize, transform: CGAffineTransform) {
        self.renderSize = renderSize
        self.transform = transform
    }

    /// Compute the layout for a source of `naturalSize` with `preferredTransform`
    /// (track orientation) targeting `preset`.
    public static func compute(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        preset: Preset
    ) -> VideoLayout {
        // Orientation-corrected display rect (may be offset/negative).
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        let target = preset.targetSize

        let scale: CGFloat
        let renderSize: CGSize
        switch preset.framing {
        case .fit:
            scale = min(target.width / displaySize.width, target.height / displaySize.height)
            renderSize = evenSize(CGSize(width: displaySize.width * scale,
                                         height: displaySize.height * scale))
        case .fill:
            scale = max(target.width / displaySize.width, target.height / displaySize.height)
            renderSize = evenSize(target)
        }

        // Orient -> move to origin -> scale -> center within the render frame.
        let normalize = CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY)
        let scaledW = displaySize.width * scale
        let scaledH = displaySize.height * scale
        let center = CGAffineTransform(translationX: (renderSize.width - scaledW) / 2,
                                       y: (renderSize.height - scaledH) / 2)
        let transform = preferredTransform
            .concatenating(normalize)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(center)

        return VideoLayout(renderSize: renderSize, transform: transform)
    }

    /// The output frame rate: the preset cap, or the source rate if it's lower.
    public static func outputFrameRate(sourceNominalFrameRate: Float, preset: Preset) -> Int {
        let source = sourceNominalFrameRate > 0 ? Int(sourceNominalFrameRate.rounded()) : preset.maxFrameRate
        return max(1, min(preset.maxFrameRate, source))
    }

    /// H.264 requires even dimensions; round each side to the nearest even int.
    public static func evenSize(_ size: CGSize) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

import CoreGraphics
import Foundation

/// The geometry of one conversion: the output render size and the affine
/// transform that maps the (oriented) source into that frame.
///
/// Pure value type from a pure function so the fit/fill/orientation/no-upscale
/// math is unit-testable without AVFoundation or a real file.
public struct VideoLayout: Equatable, Sendable {
    public let renderSize: CGSize
    public let transform: CGAffineTransform

    public init(renderSize: CGSize, transform: CGAffineTransform) {
        self.renderSize = renderSize
        self.transform = transform
    }

    /// Compute the layout for a source of `naturalSize` with `preferredTransform`
    /// mapped into `targetSize` using `framing`. The source is **never upscaled**:
    /// if the target is larger than the source can supply, the render size shrinks
    /// to the largest non-upscaled frame of the same aspect.
    public static func compute(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        targetSize: CGSize,
        framing: Framing
    ) -> VideoLayout {
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        let dw = displaySize.width, dh = displaySize.height
        let tw = targetSize.width, th = targetSize.height

        let scale: CGFloat
        let renderSize: CGSize
        switch framing {
        case .fit:
            // Clamp at 1 so we never scale the content up.
            scale = min(min(tw / dw, th / dh), 1)
            renderSize = evenSize(CGSize(width: dw * scale, height: dh * scale))
        case .fill:
            let raw = max(tw / dw, th / dh)
            if raw <= 1 {
                scale = raw
                renderSize = evenSize(targetSize)
            } else {
                // Would need upscaling to fill: shrink the frame (same aspect) to
                // the largest the source can fill at scale 1.
                scale = 1
                renderSize = evenSize(CGSize(width: tw / raw, height: th / raw))
            }
        }

        // Orient -> move to origin -> scale -> center within the render frame.
        let normalize = CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY)
        let scaledW = dw * scale
        let scaledH = dh * scale
        let center = CGAffineTransform(translationX: (renderSize.width - scaledW) / 2,
                                       y: (renderSize.height - scaledH) / 2)
        let transform = preferredTransform
            .concatenating(normalize)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(center)

        return VideoLayout(renderSize: renderSize, transform: transform)
    }

    /// True if mapping the source into `targetSize` would require upscaling.
    public static func upscales(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        targetSize: CGSize,
        framing: Framing
    ) -> Bool {
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let dw = abs(displayRect.width), dh = abs(displayRect.height)
        let tw = targetSize.width, th = targetSize.height
        let raw: CGFloat = framing == .fit ? min(tw / dw, th / dh) : max(tw / dw, th / dh)
        return raw > 1.0001
    }

    /// The output frame rate: the requested tier, or the source rate if it's lower
    /// (we never invent frames).
    public static func outputFrameRate(sourceNominalFrameRate: Float, target: TargetFrameRate) -> Int {
        let source = sourceNominalFrameRate > 0 ? Int(sourceNominalFrameRate.rounded()) : target.rawValue
        return max(1, min(target.rawValue, source))
    }

    /// H.264 requires even dimensions; round each side to the nearest even int.
    public static func evenSize(_ size: CGSize) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

import XCTest
@testable import ConvertKit

final class VideoLayoutTests: XCTestCase {
    private let identity = CGAffineTransform.identity

    private func preset(_ w: Int, _ h: Int, _ framing: Framing, fps: Int = 30) -> Preset {
        Preset(id: "t", name: "t", subtitle: "", symbol: "square",
               width: w, height: h, framing: framing, maxFrameRate: fps, videoBitrate: 1_000_000)
    }

    func testEvenSizeRoundsOddUp() {
        XCTAssertEqual(VideoLayout.evenSize(CGSize(width: 1441, height: 1079)),
                       CGSize(width: 1442, height: 1080))
    }

    func testFitPreservesAspectWithinBox() {
        // 320x240 (4:3) fit into 1920x1080 -> scale 4.5 -> 1440x1080.
        let layout = VideoLayout.compute(naturalSize: CGSize(width: 320, height: 240),
                                         preferredTransform: identity,
                                         preset: preset(1920, 1080, .fit))
        XCTAssertEqual(layout.renderSize, CGSize(width: 1440, height: 1080))
    }

    func testFillUsesExactTargetSize() {
        let layout = VideoLayout.compute(naturalSize: CGSize(width: 320, height: 240),
                                         preferredTransform: identity,
                                         preset: preset(1080, 1080, .fill))
        XCTAssertEqual(layout.renderSize, CGSize(width: 1080, height: 1080))
    }

    func testPortraitOrientationIsRespected() {
        // Landscape natural size + a 90° portrait transform => 1080x1920 display.
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let layout = VideoLayout.compute(naturalSize: CGSize(width: 1920, height: 1080),
                                         preferredTransform: portrait,
                                         preset: preset(1080, 1920, .fill))
        XCTAssertEqual(layout.renderSize, CGSize(width: 1080, height: 1920))
    }

    func testFillMapsContentToCoverFrame() {
        // After transform, the source's oriented rect must cover the render frame
        // (fill => no gaps). Check the mapped bounding box spans the render size.
        let p = preset(1080, 1080, .fill)
        let natural = CGSize(width: 640, height: 360)
        let layout = VideoLayout.compute(naturalSize: natural, preferredTransform: identity, preset: p)
        let mapped = CGRect(origin: .zero, size: natural).applying(layout.transform)
        XCTAssertLessThanOrEqual(mapped.minX, 0.5)
        XCTAssertLessThanOrEqual(mapped.minY, 0.5)
        XCTAssertGreaterThanOrEqual(mapped.maxX, layout.renderSize.width - 0.5)
        XCTAssertGreaterThanOrEqual(mapped.maxY, layout.renderSize.height - 0.5)
    }

    func testFrameRateIsCapped() {
        XCTAssertEqual(VideoLayout.outputFrameRate(sourceNominalFrameRate: 60, preset: preset(1, 1, .fit, fps: 30)), 30)
        XCTAssertEqual(VideoLayout.outputFrameRate(sourceNominalFrameRate: 24, preset: preset(1, 1, .fit, fps: 30)), 24)
        XCTAssertEqual(VideoLayout.outputFrameRate(sourceNominalFrameRate: 0, preset: preset(1, 1, .fit, fps: 30)), 30)
    }
}

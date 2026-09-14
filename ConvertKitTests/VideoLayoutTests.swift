import CoreMedia
import XCTest
@testable import ConvertKit

final class VideoLayoutTests: XCTestCase {
    private let identity = CGAffineTransform.identity

    private func layout(_ nat: CGSize, _ target: CGSize, _ framing: Framing) -> VideoLayout {
        VideoLayout.compute(naturalSize: nat, preferredTransform: identity, targetSize: target, framing: framing)
    }

    func testEvenSizeRoundsOddUp() {
        XCTAssertEqual(VideoLayout.evenSize(CGSize(width: 1441, height: 1079)),
                       CGSize(width: 1442, height: 1080))
    }

    func testFitDownscalesPreservingAspect() {
        // 3200x2400 (4:3) fit into 1920x1080 -> scale 0.45 -> 1440x1080.
        XCTAssertEqual(layout(CGSize(width: 3200, height: 2400), CGSize(width: 1920, height: 1080), .fit).renderSize,
                       CGSize(width: 1440, height: 1080))
    }

    func testFillUsesExactTargetWhenSourceIsLargeEnough() {
        XCTAssertEqual(layout(CGSize(width: 3840, height: 2160), CGSize(width: 1080, height: 1080), .fill).renderSize,
                       CGSize(width: 1080, height: 1080))
    }

    func testFitNeverUpscales() {
        // Source smaller than target box -> render stays at source size.
        XCTAssertEqual(layout(CGSize(width: 640, height: 480), CGSize(width: 1920, height: 1080), .fit).renderSize,
                       CGSize(width: 640, height: 480))
    }

    func testFillNeverUpscales() {
        // 800x600 filling a 1080x1080 frame would need 1.8x; clamp to 600x600.
        XCTAssertEqual(layout(CGSize(width: 800, height: 600), CGSize(width: 1080, height: 1080), .fill).renderSize,
                       CGSize(width: 600, height: 600))
    }

    func testUpscalesGate() {
        XCTAssertTrue(VideoLayout.upscales(naturalSize: CGSize(width: 640, height: 480),
                                           preferredTransform: identity,
                                           targetSize: CGSize(width: 1920, height: 1080), framing: .fit))
        XCTAssertFalse(VideoLayout.upscales(naturalSize: CGSize(width: 3840, height: 2160),
                                            preferredTransform: identity,
                                            targetSize: CGSize(width: 1920, height: 1080), framing: .fit))
    }

    func testPortraitOrientationIsRespected() {
        // Landscape natural size + 90° portrait transform => 1080x1920 display.
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let l = VideoLayout.compute(naturalSize: CGSize(width: 1920, height: 1080),
                                    preferredTransform: portrait,
                                    targetSize: CGSize(width: 1080, height: 1920), framing: .fill)
        XCTAssertEqual(l.renderSize, CGSize(width: 1080, height: 1920))
    }

    func testFillMapsContentToCoverFrame() {
        let nat = CGSize(width: 1920, height: 1080)
        let l = layout(nat, CGSize(width: 1080, height: 1080), .fill)
        let mapped = CGRect(origin: .zero, size: nat).applying(l.transform)
        XCTAssertLessThanOrEqual(mapped.minX, 0.5)
        XCTAssertLessThanOrEqual(mapped.minY, 0.5)
        XCTAssertGreaterThanOrEqual(mapped.maxX, l.renderSize.width - 0.5)
        XCTAssertGreaterThanOrEqual(mapped.maxY, l.renderSize.height - 0.5)
    }

    func testFrameRateIsCapped() {
        XCTAssertEqual(VideoLayout.outputFrameRate(sourceNominalFrameRate: 60, target: .fps30), 30)
        XCTAssertEqual(VideoLayout.outputFrameRate(sourceNominalFrameRate: 24, target: .fps30), 24)
        XCTAssertEqual(VideoLayout.outputFrameRate(sourceNominalFrameRate: 30, target: .fps60), 30)
        XCTAssertEqual(VideoLayout.outputFrameRate(sourceNominalFrameRate: 0, target: .fps30), 30)
    }

    func testFrameDurationKeepsSourceCadenceWhenNotReducing() {
        let ntsc = CMTime(value: 1001, timescale: 30000) // 29.97
        // 29.97 -> 30 tier: keep the exact 1001/30000 cadence, don't resample to 1/30.
        XCTAssertEqual(VideoLayout.outputFrameDuration(sourceNominalFrameRate: 29.97, sourceMinFrameDuration: ntsc,
                                                       target: .fps30), ntsc)
        let film = CMTime(value: 1001, timescale: 24000) // 23.976
        XCTAssertEqual(VideoLayout.outputFrameDuration(sourceNominalFrameRate: 23.976, sourceMinFrameDuration: film,
                                                       target: .fps30), film)
        // 60 -> 30 is a reduction: exactly 1/30.
        XCTAssertEqual(VideoLayout.outputFrameDuration(sourceNominalFrameRate: 60,
                                                       sourceMinFrameDuration: CMTime(value: 1, timescale: 60),
                                                       target: .fps30), CMTime(value: 1, timescale: 30))
        // VFR source (min frame duration far shorter than nominal): fall back to the integer rate.
        XCTAssertEqual(VideoLayout.outputFrameDuration(sourceNominalFrameRate: 30,
                                                       sourceMinFrameDuration: CMTime(value: 1, timescale: 600),
                                                       target: .fps30), CMTime(value: 1, timescale: 30))
        // Unknown min frame duration: integer rate.
        XCTAssertEqual(VideoLayout.outputFrameDuration(sourceNominalFrameRate: 30, sourceMinFrameDuration: .invalid,
                                                       target: .fps30), CMTime(value: 1, timescale: 30))
    }
}

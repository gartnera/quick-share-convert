import XCTest
@testable import ConvertKit

final class PresetTests: XCTestCase {
    func testCatalogHasInstagramPresets() {
        XCTAssertFalse(Preset.instagram.isEmpty)
        XCTAssertEqual(Preset.all.count, Preset.instagram.count)
        XCTAssertNotNil(Preset.preset(withID: "ig.reels"))
        XCTAssertNil(Preset.preset(withID: "does.not.exist"))
    }

    func testPresetIDsAreUnique() {
        let ids = Preset.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "preset ids must be unique")
    }

    func testPresetsHaveSaneAspects() {
        for preset in Preset.all {
            XCTAssertGreaterThan(preset.aspectWidth, 0, "\(preset.id) aspect width")
            XCTAssertGreaterThan(preset.aspectHeight, 0, "\(preset.id) aspect height")
        }
    }

    func testOutputSizeUsesResolutionAsShortEdge() {
        let reels = Preset.preset(withID: "ig.reels")!        // 9:16 portrait
        XCTAssertEqual(reels.outputSize(for: .fhd), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(reels.outputSize(for: .uhd), CGSize(width: 2160, height: 3840))

        let landscape = Preset.preset(withID: "ig.feed.landscape")! // 16:9
        XCTAssertEqual(landscape.outputSize(for: .fhd), CGSize(width: 1920, height: 1080))

        let square = Preset.preset(withID: "ig.square")!
        XCTAssertEqual(square.outputSize(for: .qhd), CGSize(width: 1440, height: 1440))

        let feed = Preset.preset(withID: "ig.feed.portrait")! // 4:5
        XCTAssertEqual(feed.outputSize(for: .fhd), CGSize(width: 1080, height: 1350))
    }

    func testPresetIsCodable() throws {
        let preset = Preset.instagram[0]
        let data = try JSONEncoder().encode(preset)
        XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: data), preset)
    }
}

final class TargetOptionsTests: XCTestCase {
    private let landscape = Preset.preset(withID: "ig.feed.landscape")! // 16:9

    func testAvailableResolutionsGatedBySource() {
        // A 4K source can do all tiers for a 16:9 preset.
        let uhd = SourceInfo(orientedSize: CGSize(width: 3840, height: 2160), nominalFrameRate: 30)
        XCTAssertEqual(uhd.availableResolutions(for: landscape), [.fhd, .qhd, .uhd])

        // A 1080p source can't reach 2K/4K without upscaling.
        let fhd = SourceInfo(orientedSize: CGSize(width: 1920, height: 1080), nominalFrameRate: 30)
        XCTAssertEqual(fhd.availableResolutions(for: landscape), [.fhd])
    }

    func testFrameRateGate() {
        XCTAssertTrue(SourceInfo(orientedSize: .zero, nominalFrameRate: 60).supports60fps)
        XCTAssertFalse(SourceInfo(orientedSize: .zero, nominalFrameRate: 30).supports60fps)
        XCTAssertEqual(SourceInfo(orientedSize: .zero, nominalFrameRate: 30).availableFrameRates(), [.fps30])
    }

    func testBitrateClampsToSource() {
        // Recommendation for 1080p30 is 8 Mbps; a 3 Mbps source clamps down.
        XCTAssertEqual(Bitrate.forOutput(resolution: .fhd, frameRate: .fps30, sourceDataRate: 3_000_000), 3_000_000)
        // A high-bitrate source doesn't raise it above the recommendation.
        XCTAssertEqual(Bitrate.forOutput(resolution: .fhd, frameRate: .fps30, sourceDataRate: 50_000_000),
                       Bitrate.recommended(resolution: .fhd, frameRate: .fps30))
        // Unknown source rate falls back to the recommendation.
        XCTAssertEqual(Bitrate.forOutput(resolution: .fhd, frameRate: .fps30, sourceDataRate: 0),
                       Bitrate.recommended(resolution: .fhd, frameRate: .fps30))
    }
}

final class ConversionJobTests: XCTestCase {
    func testJobCodableRoundTrip() throws {
        let job = ConversionJob(sourceFileName: "abc.mov", outputBaseName: "clip", presetID: "ig.square",
                                resolution: .qhd, frameRate: .fps60)
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(ConversionJob.self, from: data)
        XCTAssertEqual(decoded.sourceFileName, "abc.mov")
        XCTAssertEqual(decoded.presetID, "ig.square")
        XCTAssertEqual(decoded.resolution, .qhd)
        XCTAssertEqual(decoded.frameRate, .fps60)
    }

    func testJobResolvesPreset() {
        let job = ConversionJob(sourceFileName: "x.mov", outputBaseName: "x", presetID: "ig.reels",
                                resolution: .fhd, frameRate: .fps30)
        XCTAssertEqual(job.preset?.id, "ig.reels")
    }
}

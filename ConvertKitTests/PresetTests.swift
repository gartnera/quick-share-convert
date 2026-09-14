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

    func testPresetsHaveSaneValues() {
        for preset in Preset.all {
            XCTAssertGreaterThan(preset.width, 0, "\(preset.id) width")
            XCTAssertGreaterThan(preset.height, 0, "\(preset.id) height")
            XCTAssertGreaterThan(preset.videoBitrate, 0, "\(preset.id) video bitrate")
            XCTAssertGreaterThan(preset.audioBitrate, 0, "\(preset.id) audio bitrate")
            XCTAssertGreaterThan(preset.maxFrameRate, 0, "\(preset.id) fps")
        }
    }

    func testPresetIsCodable() throws {
        let preset = Preset.instagram[0]
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertEqual(preset, decoded)
    }
}

final class ConversionJobTests: XCTestCase {
    func testJobCodableRoundTrip() throws {
        let job = ConversionJob(sourceFileName: "abc.mov", outputBaseName: "clip-ig.square", presetID: "ig.square")
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(ConversionJob.self, from: data)
        XCTAssertEqual(decoded.sourceFileName, "abc.mov")
        XCTAssertEqual(decoded.outputBaseName, "clip-ig.square")
        XCTAssertEqual(decoded.presetID, "ig.square")
    }

    func testJobResolvesPreset() {
        let job = ConversionJob(sourceFileName: "x.mov", outputBaseName: "x", presetID: "ig.reels")
        XCTAssertEqual(job.preset?.id, "ig.reels")
        let bad = ConversionJob(sourceFileName: "x.mov", outputBaseName: "x", presetID: "nope")
        XCTAssertNil(bad.preset)
    }
}

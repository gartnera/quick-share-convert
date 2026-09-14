import AVFoundation
import XCTest
@testable import ConvertKit

final class VideoConverterTests: XCTestCase {
    private let converter = VideoConverter()

    private func outputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).mp4")
    }

    private func loadTrackInfo(_ url: URL) async throws -> (size: CGSize, codec: FourCharCode, primaries: String?) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let formats = try await track.load(.formatDescriptions)
        let desc = formats[0]
        let codec = CMFormatDescriptionGetMediaSubType(desc)
        let primaries = CMFormatDescriptionGetExtension(
            desc, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        return (size, codec, primaries)
    }

    func testFillSquareProducesExactSquareH264() async throws {
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 320, height: 240))
        let out = outputURL()
        _ = try await converter.convert(sourceURL: source, preset: Preset.preset(withID: "ig.square")!,
                                        outputURL: out) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let info = try await loadTrackInfo(out)
        XCTAssertEqual(info.size, CGSize(width: 1080, height: 1080))
        XCTAssertEqual(info.codec, kCMVideoCodecType_H264)
    }

    func testFitLandscapePreservesAspect() async throws {
        // 320x240 (4:3) into the 1920x1080 fit box -> 1440x1080.
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 320, height: 240))
        let out = outputURL()
        _ = try await converter.convert(sourceURL: source, preset: Preset.preset(withID: "ig.feed.landscape")!,
                                        outputURL: out) { _ in }
        let info = try await loadTrackInfo(out)
        XCTAssertEqual(info.size, CGSize(width: 1440, height: 1080))
    }

    func testOutputIsTaggedSDRRec709() async throws {
        // HDR is always stripped: the output must be tagged Rec.709 primaries.
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 640, height: 360))
        let out = outputURL()
        _ = try await converter.convert(sourceURL: source, preset: Preset.preset(withID: "ig.reels")!,
                                        outputURL: out) { _ in }
        let info = try await loadTrackInfo(out)
        XCTAssertEqual(info.primaries as String?, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
    }

    func testProgressReachesCompletion() async throws {
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 320, height: 240))
        let out = outputURL()
        var last = 0.0
        _ = try await converter.convert(sourceURL: source, preset: Preset.preset(withID: "ig.square")!,
                                        outputURL: out) { p in last = max(last, p) }
        XCTAssertEqual(last, 1.0, accuracy: 0.0001)
    }

    func testMissingVideoTrackThrows() async throws {
        // A text file is not a valid movie -> noVideoTrack / read error.
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("bogus-\(UUID().uuidString).mp4")
        try "not a video".data(using: .utf8)!.write(to: bogus)
        do {
            _ = try await converter.convert(sourceURL: bogus, preset: Preset.instagram[0],
                                            outputURL: outputURL()) { _ in }
            XCTFail("expected an error")
        } catch {
            // expected
        }
    }
}

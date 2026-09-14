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
        let desc = try await track.load(.formatDescriptions)[0]
        let primaries = CMFormatDescriptionGetExtension(
            desc, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        return (size, CMFormatDescriptionGetMediaSubType(desc), primaries)
    }

    func testFillSquareProducesExactSquareH264() async throws {
        // 1920x1080 source is large enough to make an exact 1080x1080 square.
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 1920, height: 1080))
        let out = outputURL()
        _ = try await converter.convert(sourceURL: source, preset: Preset.preset(withID: "ig.square")!,
                                        resolution: .fhd, frameRate: .fps30, outputURL: out) { _ in }
        let info = try await loadTrackInfo(out)
        XCTAssertEqual(info.size, CGSize(width: 1080, height: 1080))
        XCTAssertEqual(info.codec, kCMVideoCodecType_H264)
    }

    func testFitLandscapePreservesAspect() async throws {
        // 1920x1440 (4:3) into the 16:9 fit box at 1080 -> 1440x1080.
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 1920, height: 1440))
        let out = outputURL()
        _ = try await converter.convert(sourceURL: source, preset: Preset.preset(withID: "ig.feed.landscape")!,
                                        resolution: .fhd, frameRate: .fps30, outputURL: out) { _ in }
        let info = try await loadTrackInfo(out)
        XCTAssertEqual(info.size, CGSize(width: 1440, height: 1080))
    }

    func testNeverUpscalesBeyondSource() async throws {
        // 640x480 source asked for 4K square -> clamped to 480x480 (no upscale).
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 640, height: 480))
        let out = outputURL()
        _ = try await converter.convert(sourceURL: source, preset: Preset.preset(withID: "ig.square")!,
                                        resolution: .uhd, frameRate: .fps30, outputURL: out) { _ in }
        let info = try await loadTrackInfo(out)
        XCTAssertEqual(info.size, CGSize(width: 480, height: 480))
    }

    func testOutputIsTaggedSDRRec709() async throws {
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 1920, height: 1080))
        let out = outputURL()
        _ = try await converter.convert(sourceURL: source, preset: Preset.preset(withID: "ig.square")!,
                                        resolution: .fhd, frameRate: .fps30, outputURL: out) { _ in }
        let info = try await loadTrackInfo(out)
        XCTAssertEqual(info.primaries as String?, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
    }

    func testProgressReachesCompletion() async throws {
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 1280, height: 720))
        let out = outputURL()
        var last = 0.0
        _ = try await converter.convert(sourceURL: source, preset: Preset.preset(withID: "ig.square")!,
                                        resolution: .fhd, frameRate: .fps30, outputURL: out) { last = max(last, $0) }
        XCTAssertEqual(last, 1.0, accuracy: 0.0001)
    }

    func testLoadSourceInfo() async throws {
        let source = try await TestVideoFactory.makeVideo(size: CGSize(width: 1280, height: 720), fps: 30)
        let info = try await VideoConverter.loadSourceInfo(url: source)
        XCTAssertEqual(info.orientedSize, CGSize(width: 1280, height: 720))
        XCTAssertFalse(info.supports60fps)
    }

    func testMissingVideoTrackThrows() async throws {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("bogus-\(UUID().uuidString).mp4")
        try "not a video".data(using: .utf8)!.write(to: bogus)
        do {
            _ = try await converter.convert(sourceURL: bogus, preset: Preset.instagram[0],
                                            resolution: .fhd, frameRate: .fps30, outputURL: outputURL()) { _ in }
            XCTFail("expected an error")
        } catch {}
    }
}

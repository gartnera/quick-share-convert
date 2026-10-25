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
        XCTAssertEqual(uhd.availableResolutions(for: landscape), [.hd, .fhd, .qhd, .uhd])

        // A 1080p source can't reach 2K/4K without upscaling, but can step down to 720p.
        let fhd = SourceInfo(orientedSize: CGSize(width: 1920, height: 1080), nominalFrameRate: 30)
        XCTAssertEqual(fhd.availableResolutions(for: landscape), [.hd, .fhd])
    }

    func testFrameRateGate() {
        XCTAssertTrue(SourceInfo(orientedSize: .zero, nominalFrameRate: 60).supports60fps)
        XCTAssertFalse(SourceInfo(orientedSize: .zero, nominalFrameRate: 30).supports60fps)
        XCTAssertEqual(SourceInfo(orientedSize: .zero, nominalFrameRate: 30).availableFrameRates(), [.fps30])
    }

    func testBitrateClampsToSource() {
        let fhd16x9 = CGSize(width: 1920, height: 1080)
        // Recommendation for 1080p30 is 8 Mbps; a 3 Mbps H.264 source clamps down.
        XCTAssertEqual(Bitrate.forOutput(renderSize: fhd16x9, resolution: .fhd, frameRate: .fps30,
                                         sourceDataRate: 3_000_000, sourceIsHEVC: false), 3_000_000)
        // A high-bitrate source doesn't raise it above the recommendation.
        XCTAssertEqual(Bitrate.forOutput(renderSize: fhd16x9, resolution: .fhd, frameRate: .fps30,
                                         sourceDataRate: 50_000_000, sourceIsHEVC: false),
                       Bitrate.recommended(resolution: .fhd, frameRate: .fps30))
        // Unknown source rate falls back to the recommendation.
        XCTAssertEqual(Bitrate.forOutput(renderSize: fhd16x9, resolution: .fhd, frameRate: .fps30,
                                         sourceDataRate: 0, sourceIsHEVC: false),
                       Bitrate.recommended(resolution: .fhd, frameRate: .fps30))
    }

    func testBitrateCapIsWiderForHEVCSources() {
        // A 6 Mbps HEVC clip needs ~9 Mbps of H.264 for equal quality; the 8 Mbps
        // recommendation stands instead of being clamped to 6.
        let fhd16x9 = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(Bitrate.forOutput(renderSize: fhd16x9, resolution: .fhd, frameRate: .fps30,
                                         sourceDataRate: 6_000_000, sourceIsHEVC: true), 8_000_000)
        XCTAssertEqual(Bitrate.forOutput(renderSize: fhd16x9, resolution: .fhd, frameRate: .fps30,
                                         sourceDataRate: 4_000_000, sourceIsHEVC: true), 6_000_000)
    }

    func testBitrateScalesWithRenderArea() {
        // 16:9 and 9:16 at 1080 cover the full reference area -> table value.
        XCTAssertEqual(Bitrate.recommended(renderSize: CGSize(width: 1080, height: 1920),
                                           resolution: .fhd, frameRate: .fps30), 8_000_000)
        // A 1080x1080 square is 9/16 of the area -> 4.5 Mbps.
        XCTAssertEqual(Bitrate.recommended(renderSize: CGSize(width: 1080, height: 1080),
                                           resolution: .fhd, frameRate: .fps30), 4_500_000)
        // 4:5 feed portrait 1080x1350 -> 5.625 Mbps.
        XCTAssertEqual(Bitrate.recommended(renderSize: CGSize(width: 1080, height: 1350),
                                           resolution: .fhd, frameRate: .fps30), 5_625_000)
        // 60fps is 1.5x.
        XCTAssertEqual(Bitrate.recommended(renderSize: CGSize(width: 1920, height: 1080),
                                           resolution: .fhd, frameRate: .fps60), 12_000_000)
        // A no-upscale-clamped tiny frame never drops below the floor.
        XCTAssertEqual(Bitrate.recommended(renderSize: CGSize(width: 240, height: 240),
                                           resolution: .uhd, frameRate: .fps30), Bitrate.minimum)
    }

    func testAudioSettingsFollowSource() {
        XCTAssertEqual(Bitrate.audioSampleRate(source: 48_000), 48_000)
        XCTAssertEqual(Bitrate.audioSampleRate(source: 44_100), 44_100)
        XCTAssertEqual(Bitrate.audioSampleRate(source: 96_000), 48_000)
        XCTAssertEqual(Bitrate.audioSampleRate(source: 22_050), 48_000)
        XCTAssertEqual(Bitrate.audioChannels(source: 1), 1)
        XCTAssertEqual(Bitrate.audioChannels(source: 2), 2)
        XCTAssertEqual(Bitrate.audioChannels(source: 6), 2)
    }
}

final class ConversionJobTests: XCTestCase {

    func testJobCodableRoundTrip() throws {
        let all: [ConversionSettings] = [
            .video(presetID: "ig.square", resolution: .qhd, frameRate: .fps60),
            .photo(PhotoOptions(format: .heic, size: .medium, quality: .low)),
            .audio(AudioOptions(codec: .flac, bitrate: .kbps192)),
        ]
        for settings in all {
            let job = ConversionJob(sourceFileName: "abc", outputBaseName: "clip", settings: settings)
            let data = try JSONEncoder().encode(job)
            let decoded = try JSONDecoder().decode(ConversionJob.self, from: data)
            XCTAssertEqual(decoded.sourceFileName, "abc")
            XCTAssertEqual(decoded.settings, settings)
        }
    }

    func testSettingsNameSuffixAndKind() {
        let video = ConversionSettings.video(presetID: "ig.reels", resolution: .fhd, frameRate: .fps30)
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.nameSuffix, "ig.reels")
        XCTAssertEqual(video.progressTitle, "Converting for Reels / Stories")
        XCTAssertEqual(ConversionSettings.photo(PhotoOptions(size: .medium)).nameSuffix, "2048px")
        XCTAssertEqual(ConversionSettings.photo(PhotoOptions()).nameSuffix, "full")
        XCTAssertEqual(ConversionSettings.audio(AudioOptions(codec: .aac, bitrate: .kbps192)).nameSuffix, "192k")
        XCTAssertEqual(ConversionSettings.audio(AudioOptions(codec: .flac)).nameSuffix, "flac")
    }

    func testMediaKindDetection() {
        XCTAssertEqual(MediaKind.detect(typeIdentifiers: ["com.apple.quicktime-movie"]), .video)
        XCTAssertEqual(MediaKind.detect(typeIdentifiers: ["public.heic", "public.jpeg"]), .photo)
        XCTAssertEqual(MediaKind.detect(typeIdentifiers: ["public.mp3"]), .audio)
        XCTAssertEqual(MediaKind.detect(typeIdentifiers: ["com.apple.m4a-audio"]), .audio)
        XCTAssertEqual(MediaKind.detect(typeIdentifiers: ["com.microsoft.waveform-audio"]), .audio)
        XCTAssertNil(MediaKind.detect(typeIdentifiers: ["public.plain-text"]))
        XCTAssertEqual(MediaKind.photo.preferredTypeIdentifier(in: ["public.file-url", "public.heic", "public.jpeg"]),
                       "public.heic")
    }
}

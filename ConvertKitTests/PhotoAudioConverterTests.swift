import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ConvertKit

final class PhotoConverterTests: XCTestCase {
    private let converter = PhotoConverter()

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).\(ext)")
    }

    /// Writes a solid test image, optionally with an EXIF orientation and GPS tag.
    private func makeImage(width: Int, height: Int, type: UTType = .jpeg, orientation: Int = 1,
                           alpha: Bool = false) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = tempURL(type.preferredFilenameExtension ?? "img")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func properties(_ url: URL) -> [CFString: Any] {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testSourceInfoAccountsForOrientation() throws {
        let url = try makeImage(width: 400, height: 300, orientation: 6) // rotated 90°
        let info = try PhotoConverter.loadSourceInfo(url: url)
        XCTAssertEqual(info.orientedSize, CGSize(width: 300, height: 400))
        XCTAssertEqual(info.formatName, "JPEG")
    }

    func testAvailableSizesOnlyOfferRealDownscales() {
        let big = PhotoInfo(orientedSize: CGSize(width: 8064, height: 6048), typeIdentifier: nil)
        XCTAssertEqual(big.availableSizes(), [.original, .large, .medium, .small])
        let mid = PhotoInfo(orientedSize: CGSize(width: 2048, height: 1536), typeIdentifier: nil)
        XCTAssertEqual(mid.availableSizes(), [.original, .small])
        let tiny = PhotoInfo(orientedSize: CGSize(width: 640, height: 480), typeIdentifier: nil)
        XCTAssertEqual(tiny.availableSizes(), [.original])
    }

    func testOriginalSizeBakesOrientationAndKeepsMetadata() async throws {
        let src = try makeImage(width: 400, height: 300, orientation: 6)
        let out = try await converter.convert(sourceURL: src, options: PhotoOptions(format: .jpeg, size: .original),
                                              outputURL: tempURL("jpg"))
        let props = properties(out)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 300)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 400)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFOrientation] as? Int ?? 1, 1)
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "Test Camera")
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:05:06 07:08:09")
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude] as? Double, 37.0)
        XCTAssertEqual(try PhotoConverter.loadSourceInfo(url: out).typeIdentifier, UTType.jpeg.identifier)
    }

    func testDownscaleUpdatesExifDimensions() async throws {
        let src = try makeImage(width: 3000, height: 2000)
        let out = try await converter.convert(sourceURL: src, options: PhotoOptions(size: .small),
                                              outputURL: tempURL("jpg"))
        let exif = properties(out)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifPixelXDimension] as? Int, 1080)
        XCTAssertEqual(exif?[kCGImagePropertyExifPixelYDimension] as? Int, 720)
    }

    func testDownscaleKeepsAspect() async throws {
        let src = try makeImage(width: 3000, height: 2000)
        let out = try await converter.convert(sourceURL: src, options: PhotoOptions(size: .medium),
                                              outputURL: tempURL("jpg"))
        let info = try PhotoConverter.loadSourceInfo(url: out)
        XCTAssertEqual(info.orientedSize.width, 2048)
        XCTAssertEqual(info.orientedSize.height, 1365, accuracy: 1)
    }

    func testSizeCapNeverUpscales() async throws {
        let src = try makeImage(width: 800, height: 600)
        let out = try await converter.convert(sourceURL: src, options: PhotoOptions(size: .small),
                                              outputURL: tempURL("jpg"))
        XCTAssertEqual(try PhotoConverter.loadSourceInfo(url: out).orientedSize, CGSize(width: 800, height: 600))
    }

    func testLowerQualityIsSmaller() async throws {
        let src = try makeImage(width: 1200, height: 900)
        let high = try await converter.convert(sourceURL: src, options: PhotoOptions(quality: .high),
                                               outputURL: tempURL("jpg"))
        let low = try await converter.convert(sourceURL: src, options: PhotoOptions(quality: .low),
                                              outputURL: tempURL("jpg"))
        func size(_ u: URL) throws -> Int { try u.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        XCTAssertLessThanOrEqual(try size(low), try size(high))
    }

    func testTransparentPNGToJPEG() async throws {
        let src = try makeImage(width: 200, height: 100, type: .png, alpha: true)
        let out = try await converter.convert(sourceURL: src, options: PhotoOptions(format: .jpeg),
                                              outputURL: tempURL("jpg"))
        XCTAssertEqual(try PhotoConverter.loadSourceInfo(url: out).orientedSize, CGSize(width: 200, height: 100))
    }

    func testHEICOutput() async throws {
        try XCTSkipUnless(PhotoFormat.heic.isEncodable, "no HEIC encoder on this machine")
        let src = try makeImage(width: 600, height: 400)
        let out = try await converter.convert(sourceURL: src, options: PhotoOptions(format: .heic),
                                              outputURL: tempURL("heic"))
        XCTAssertEqual(try PhotoConverter.loadSourceInfo(url: out).typeIdentifier, UTType.heic.identifier)
    }

    func testNonImageThrows() async throws {
        let bogus = tempURL("jpg")
        try Data("not an image".utf8).write(to: bogus)
        do {
            _ = try await converter.convert(sourceURL: bogus, options: PhotoOptions(), outputURL: tempURL("jpg"))
            XCTFail("expected unreadableImage")
        } catch ConversionError.unreadableImage {}
    }
}

final class AudioConverterTests: XCTestCase {
    private let converter = AudioConverter()

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString).\(ext)")
    }

    /// A 16-bit (or 24-bit) PCM WAV holding a 440 Hz tone.
    private func makeWAV(sampleRate: Double, channels: Int, bits: Int = 16, seconds: Double = 1) throws -> URL {
        let url = tempURL("wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<channels {
            let data = buffer.floatChannelData![c]
            for i in 0..<Int(frames) { data[i] = Float(sin(Double(i) * 2 * .pi * 440 / sampleRate) * 0.3) }
        }
        try file.write(from: buffer)
        return url
    }

    private func convert(_ src: URL, _ options: AudioOptions) async throws -> AudioInfo {
        let out = try await converter.convert(sourceURL: src, options: options,
                                              outputURL: tempURL(options.codec.fileExtension)) { _ in }
        return try AudioConverter.loadSourceInfo(url: out)
    }

    func testLoadSourceInfo() throws {
        let info = try AudioConverter.loadSourceInfo(url: makeWAV(sampleRate: 44_100, channels: 2))
        XCTAssertEqual(info.sampleRate, 44_100)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.bitsPerChannel, 16)
        XCTAssertEqual(info.codecName, "PCM")
        XCTAssertTrue(info.isLossless)
        XCTAssertEqual(info.duration, 1, accuracy: 0.01)
    }

    func testWAVToAACAt48kStereo() async throws {
        let info = try await convert(makeWAV(sampleRate: 48_000, channels: 2), AudioOptions(codec: .aac, bitrate: .kbps256))
        XCTAssertEqual(info.formatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(info.sampleRate, 48_000)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.duration, 1, accuracy: 0.05)
    }

    func testMonoStaysMonoAndHighRateDropsTo48kForAAC() async throws {
        let mono = try await convert(makeWAV(sampleRate: 44_100, channels: 1), AudioOptions(codec: .aac, bitrate: .kbps128))
        XCTAssertEqual(mono.channels, 1)
        XCTAssertEqual(mono.sampleRate, 44_100)

        let hiRes = try await convert(makeWAV(sampleRate: 96_000, channels: 2), AudioOptions(codec: .aac))
        XCTAssertEqual(hiRes.sampleRate, 48_000)
    }

    func testEveryBitrateEncodesMonoAndStereo() async throws {
        for channels in [1, 2] {
            let src = try makeWAV(sampleRate: 48_000, channels: channels)
            for bitrate in AudioBitrate.allCases {
                let info = try await convert(src, AudioOptions(codec: .aac, bitrate: bitrate))
                XCTAssertEqual(info.channels, channels, "\(bitrate.label) ch=\(channels)")
            }
        }
    }

    func testLosslessCodecsKeepSourceFormat() async throws {
        let src = try makeWAV(sampleRate: 96_000, channels: 2, bits: 24)
        for (codec, id) in [(AudioCodec.alac, kAudioFormatAppleLossless), (.flac, kAudioFormatFLAC),
                            (.wav, kAudioFormatLinearPCM)] {
            let info = try await convert(src, AudioOptions(codec: codec))
            XCTAssertEqual(info.formatID, id, codec.label)
            XCTAssertEqual(info.sampleRate, 96_000, codec.label)
            XCTAssertEqual(info.channels, 2, codec.label)
            XCTAssertEqual(info.duration, 1, accuracy: 0.01, codec.label)
        }
    }

    func testLossyToLosslessRoundTrip() async throws {
        let aacOut = try await converter.convert(sourceURL: makeWAV(sampleRate: 44_100, channels: 2),
                                                 options: AudioOptions(codec: .aac), outputURL: tempURL("m4a")) { _ in }
        let flac = try await convert(aacOut, AudioOptions(codec: .flac))
        XCTAssertEqual(flac.formatID, kAudioFormatFLAC)
        XCTAssertEqual(flac.sampleRate, 44_100)
    }

    func testProgressReachesCompletion() async throws {
        let src = try makeWAV(sampleRate: 48_000, channels: 2, seconds: 2)
        var last = 0.0
        _ = try await converter.convert(sourceURL: src, options: AudioOptions(), outputURL: tempURL("m4a")) { last = $0 }
        XCTAssertEqual(last, 1.0)
    }

    func testSuggestedBitrateFollowsLossySource() {
        func info(_ format: AudioFormatID, rate: Double) -> AudioInfo {
            AudioInfo(duration: 60, sampleRate: 44_100, channels: 2, bitsPerChannel: 0, formatID: format, dataRate: rate)
        }
        XCTAssertEqual(info(kAudioFormatMPEGLayer3, rate: 128_500).suggestedBitrate, .kbps128)
        XCTAssertEqual(info(kAudioFormatMPEGLayer3, rate: 160_000).suggestedBitrate, .kbps192)
        XCTAssertEqual(info(kAudioFormatMPEGLayer3, rate: 320_000).suggestedBitrate, .kbps256)
        XCTAssertEqual(info(kAudioFormatLinearPCM, rate: 1_411_200).suggestedBitrate, .kbps256)
    }

    private func sampleTags() throws -> AudioTags {
        var t = AudioTags()
        t.title = "Song Title"
        t.artist = "The Artist"
        t.album = "An Album"
        t.albumArtist = "Various"
        t.genre = "Electronic"
        t.year = "2021"
        t.trackNumber = 3
        t.trackCount = 12
        t.discNumber = 1
        t.discCount = 2
        t.composer = "Composer Person"
        t.comment = "ünïcödé comment"
        t.copyright = "© 2021"
        // A tiny real PNG for cover art.
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let png = NSMutableData()
        let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        t.artwork = png as Data
        return t
    }

    private func taggedFLAC() async throws -> (URL, AudioTags) {
        let url = try await converter.convert(sourceURL: makeWAV(sampleRate: 44_100, channels: 2),
                                              options: AudioOptions(codec: .flac), outputURL: tempURL("flac")) { _ in }
        let tags = try sampleTags()
        try await tags.write(to: url)
        return (url, tags)
    }

    func testFLACTagsRoundTripAndStayDecodable() async throws {
        let (url, tags) = try await taggedFLAC()
        let read = await AudioTags.read(from: url)
        XCTAssertEqual(read, tags)
        let info = try AudioConverter.loadSourceInfo(url: url)
        XCTAssertEqual(info.formatID, kAudioFormatFLAC)
        XCTAssertEqual(info.duration, 1, accuracy: 0.01)
    }

    func testTagsCarryThroughM4AAndBackToFLAC() async throws {
        let (flac, tags) = try await taggedFLAC()
        for codec in [AudioCodec.aac, .alac] {
            let m4a = try await converter.convert(sourceURL: flac, options: AudioOptions(codec: codec),
                                                  outputURL: tempURL("m4a")) { _ in }
            let m4aTags = await AudioTags.read(from: m4a)
            XCTAssertEqual(m4aTags, tags, codec.label)
            XCTAssertEqual(try AudioConverter.loadSourceInfo(url: m4a).duration, 1, accuracy: 0.05, codec.label)

            let back = try await converter.convert(sourceURL: m4a, options: AudioOptions(codec: .flac),
                                                   outputURL: tempURL("flac")) { _ in }
            let backTags = await AudioTags.read(from: back)
            XCTAssertEqual(backTags, tags, "\(codec.label) -> FLAC")
        }
    }

    func testTagsCarryIntoWAVInfo() async throws {
        let (flac, tags) = try await taggedFLAC()
        let wav = try await converter.convert(sourceURL: flac, options: AudioOptions(codec: .wav),
                                              outputURL: tempURL("wav")) { _ in }
        let read = await AudioTags.read(from: wav)
        // RIFF INFO has no album artist, disc or artwork fields.
        var expected = tags
        expected.albumArtist = nil; expected.discNumber = nil; expected.discCount = nil; expected.artwork = nil
        XCTAssertEqual(read, expected)
        let info = try AudioConverter.loadSourceInfo(url: wav)
        XCTAssertEqual(info.duration, 1, accuracy: 0.01)
        XCTAssertEqual(info.channels, 2)
    }

    func testUntaggedSourceStaysUntagged() async throws {
        let out = try await converter.convert(sourceURL: makeWAV(sampleRate: 44_100, channels: 1),
                                              options: AudioOptions(codec: .flac), outputURL: tempURL("flac")) { _ in }
        let tags = await AudioTags.read(from: out)
        XCTAssertTrue(tags.isEmpty)
    }

    func testNonAudioThrows() async throws {
        let bogus = tempURL("mp3")
        try Data("not audio".utf8).write(to: bogus)
        do {
            _ = try await convert(bogus, AudioOptions())
            XCTFail("expected noAudioTrack")
        } catch ConversionError.noAudioTrack {}
    }
}

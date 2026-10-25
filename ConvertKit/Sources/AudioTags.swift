import AVFoundation
import Foundation

/// Song tags carried from the source file to the converted one.
///
/// Read from whatever the source has (ID3 in MP3, iTunes atoms in M4A, Vorbis
/// comments in FLAC, RIFF INFO in WAV) and written in the output's native form.
/// Core Audio's own tag API only writes CAF, and AVAudioFile doesn't carry tags
/// at all, so FLAC and WAV are handled here directly.
public struct AudioTags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    /// Release year or date as written in the source, e.g. "2020".
    public var year: String?
    public var trackNumber: Int?
    public var trackCount: Int?
    public var discNumber: Int?
    public var discCount: Int?
    public var composer: String?
    public var comment: String?
    public var copyright: String?
    /// Cover art bytes (JPEG or PNG).
    public var artwork: Data?

    public init() {}

    public var isEmpty: Bool { self == AudioTags() }

    // MARK: - Read

    public static func read(from url: URL) async -> AudioTags {
        var tags = AudioTags()
        switch url.pathExtension.lowercased() {
        case "flac": tags = (try? FLACTags.read(url)) ?? AudioTags()
        case "wav", "wave": tags = (try? RIFFInfo.read(url)) ?? AudioTags()
        default: break
        }
        // AVFoundation covers ID3, iTunes and QuickTime metadata; it only fills
        // what the format-specific readers above didn't.
        let items = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        for item in items { await tags.merge(item) }
        return tags
    }

    private mutating func merge(_ item: AVMetadataItem) async {
        let string = { (try? await item.load(.stringValue))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        func fill(_ field: WritableKeyPath<AudioTags, String?>) async {
            if self[keyPath: field] == nil, let s = await string(), !s.isEmpty { self[keyPath: field] = s }
        }

        switch item.commonKey {
        case .commonKeyTitle?: await fill(\.title)
        case .commonKeyArtist?: await fill(\.artist)
        case .commonKeyAlbumName?: await fill(\.album)
        case .commonKeyCopyrights?: await fill(\.copyright)
        case .commonKeyArtwork?:
            if artwork == nil, let data = try? await item.load(.dataValue), Self.imageMIME(data) != nil {
                artwork = data
            }
        default: break
        }

        switch item.identifier {
        case .iTunesMetadataAlbumArtist?, .id3MetadataBand?: await fill(\.albumArtist)
        case .iTunesMetadataUserGenre?, .id3MetadataContentType?: await fill(\.genre)
        case .iTunesMetadataReleaseDate?, .id3MetadataYear?, .id3MetadataRecordingTime?: await fill(\.year)
        case .iTunesMetadataComposer?, .id3MetadataComposer?: await fill(\.composer)
        case .iTunesMetadataUserComment?, .id3MetadataComments?: await fill(\.comment)
        case .iTunesMetadataTrackNumber?:
            if trackNumber == nil, let d = try? await item.load(.dataValue) { (trackNumber, trackCount) = Self.pair(atom: d) }
        case .iTunesMetadataDiscNumber?:
            if discNumber == nil, let d = try? await item.load(.dataValue) { (discNumber, discCount) = Self.pair(atom: d) }
        case .id3MetadataTrackNumber?:
            if trackNumber == nil, let s = await string() { (trackNumber, trackCount) = Self.pair(slashed: s) }
        case .id3MetadataPartOfASet?:
            if discNumber == nil, let s = await string() { (discNumber, discCount) = Self.pair(slashed: s) }
        default: break
        }
    }

    // MARK: - Write

    /// Writes the tags into a freshly converted file, in its native form.
    public func write(to url: URL) async throws {
        guard !isEmpty else { return }
        switch url.pathExtension.lowercased() {
        case "flac": try FLACTags.write(self, to: url)
        case "wav", "wave": try RIFFInfo.write(self, to: url)
        case "m4a", "mp4": try await writeMPEG4(to: url)
        default: break
        }
    }

    /// Remuxes (no re-encode) with iTunes metadata atoms.
    private func writeMPEG4(to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url),
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError.writerFailed("could not tag the file")
        }
        session.metadata = iTunesItems()
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("tagging-\(UUID().uuidString).\(url.pathExtension)")
        try await session.export(to: tmp, as: .m4a)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    func iTunesItems() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ id: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, dataType: CFString? = nil) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value
            if let dataType { item.dataType = dataType as String }
            items.append(item)
        }
        add(.iTunesMetadataSongName, title as NSString?)
        add(.iTunesMetadataArtist, artist as NSString?)
        add(.iTunesMetadataAlbum, album as NSString?)
        add(.iTunesMetadataAlbumArtist, albumArtist as NSString?)
        add(.iTunesMetadataUserGenre, genre as NSString?)
        add(.iTunesMetadataReleaseDate, year as NSString?)
        add(.iTunesMetadataComposer, composer as NSString?)
        add(.iTunesMetadataUserComment, comment as NSString?)
        add(.iTunesMetadataCopyright, copyright as NSString?)
        if let trackNumber {
            add(.iTunesMetadataTrackNumber, Self.atom(trackNumber, trackCount) as NSData,
                dataType: kCMMetadataBaseDataType_RawData)
        }
        if let discNumber {
            add(.iTunesMetadataDiscNumber, Self.atom(discNumber, discCount) as NSData,
                dataType: kCMMetadataBaseDataType_RawData)
        }
        if let artwork, let mime = Self.imageMIME(artwork) {
            add(.iTunesMetadataCoverArt, artwork as NSData,
                dataType: mime == "image/png" ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG)
        }
        return items
    }

    // MARK: - Helpers

    /// "3/12" -> (3, 12); "3" -> (3, nil).
    static func pair(slashed s: String) -> (Int?, Int?) {
        let parts = s.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        return (parts.first ?? nil, parts.count > 1 ? parts[1] : nil)
    }

    /// iTunes trkn/disk atom: 2 pad bytes, number (BE16), count (BE16), 2 pad bytes.
    static func pair(atom d: Data) -> (Int?, Int?) {
        let b = [UInt8](d)
        guard b.count >= 6 else { return (nil, nil) }
        let n = Int(b[2]) << 8 | Int(b[3]), c = Int(b[4]) << 8 | Int(b[5])
        return (n > 0 ? n : nil, c > 0 ? c : nil)
    }

    static func atom(_ n: Int, _ c: Int?) -> Data {
        let c = c ?? 0
        return Data([0, 0, UInt8(n >> 8 & 0xff), UInt8(n & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff), 0, 0])
    }

    static func imageMIME(_ d: Data) -> String? {
        if d.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        return nil
    }
}

// MARK: - FLAC (Vorbis comment + PICTURE metadata blocks)

enum FLACTags {
    private static let vorbisComment: UInt8 = 4
    private static let picture: UInt8 = 6

    private struct Block { let type: UInt8; let body: Data }

    private static func parse(_ data: Data) throws -> (blocks: [Block], audioStart: Int) {
        let b = [UInt8](data.prefix(4))
        guard b == Array("fLaC".utf8) else { throw ConversionError.readerFailed("not a FLAC file") }
        var pos = 4, blocks: [Block] = []
        while pos + 4 <= data.count {
            let header = data[pos]
            let len = Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            guard pos + 4 + len <= data.count else { throw ConversionError.readerFailed("truncated FLAC metadata") }
            blocks.append(Block(type: header & 0x7f, body: data.subdata(in: pos + 4 ..< pos + 4 + len)))
            pos += 4 + len
            if header & 0x80 != 0 { break }
        }
        return (blocks, pos)
    }

    static func read(_ url: URL) throws -> AudioTags {
        var tags = AudioTags()
        for block in try parse(try Data(contentsOf: url, options: .mappedIfSafe)).blocks {
            if block.type == vorbisComment {
                var r = ByteReader(block.body)
                _ = r.string(r.le32())               // vendor
                for _ in 0 ..< r.le32() {
                    guard let entry = r.string(r.le32()), let eq = entry.firstIndex(of: "=") else { continue }
                    tags.set(vorbisKey: entry[..<eq].uppercased(), value: String(entry[entry.index(after: eq)...]))
                }
            } else if block.type == picture, tags.artwork == nil {
                var r = ByteReader(block.body)
                _ = r.be32()                          // picture type
                _ = r.string(r.be32())                // MIME
                _ = r.string(r.be32())                // description
                _ = (r.be32(), r.be32(), r.be32(), r.be32()) // width, height, depth, colors
                tags.artwork = r.bytes(r.be32())
            }
        }
        return tags
    }

    static func write(_ tags: AudioTags, to url: URL) throws {
        let data = try Data(contentsOf: url)
        let (old, audioStart) = try parse(data)
        var blocks = old.filter { $0.type != vorbisComment && $0.type != picture }
        let insertAt = min(1, blocks.count) // right after STREAMINFO
        var extra = [Block(type: vorbisComment, body: commentBody(tags))]
        if let art = tags.artwork, let mime = AudioTags.imageMIME(art) {
            extra.append(Block(type: picture, body: pictureBody(art, mime: mime)))
        }
        blocks.insert(contentsOf: extra, at: insertAt)

        var out = Data("fLaC".utf8)
        for (i, block) in blocks.enumerated() {
            let last: UInt8 = i == blocks.count - 1 ? 0x80 : 0
            let n = block.body.count
            out.append(contentsOf: [last | block.type, UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
            out.append(block.body)
        }
        out.append(data.subdata(in: audioStart ..< data.count))
        try out.write(to: url, options: .atomic)
    }

    private static func commentBody(_ t: AudioTags) -> Data {
        let fields: [(String, String?)] = [
            ("TITLE", t.title), ("ARTIST", t.artist), ("ALBUM", t.album), ("ALBUMARTIST", t.albumArtist),
            ("GENRE", t.genre), ("DATE", t.year), ("TRACKNUMBER", t.trackNumber.map(String.init)),
            ("TRACKTOTAL", t.trackCount.map(String.init)), ("DISCNUMBER", t.discNumber.map(String.init)),
            ("DISCTOTAL", t.discCount.map(String.init)), ("COMPOSER", t.composer), ("COMMENT", t.comment),
            ("COPYRIGHT", t.copyright),
        ]
        let entries = fields.compactMap { k, v in v.map { Data("\(k)=\($0)".utf8) } }
        let vendor = Data("Quick Convert".utf8)
        var w = ByteWriter()
        w.le32(vendor.count); w.data(vendor)
        w.le32(entries.count)
        for e in entries { w.le32(e.count); w.data(e) }
        return w.out
    }

    private static func pictureBody(_ art: Data, mime: String) -> Data {
        var w = ByteWriter()
        w.be32(3)                                    // front cover
        let m = Data(mime.utf8); w.be32(m.count); w.data(m)
        w.be32(0)                                    // empty description
        w.be32(0); w.be32(0); w.be32(0); w.be32(0)   // width, height, depth, colors: unknown
        w.be32(art.count); w.data(art)
        return w.out
    }
}

private extension AudioTags {
    mutating func set(vorbisKey key: String, value: String) {
        switch key {
        case "TITLE": title = title ?? value
        case "ARTIST": artist = artist ?? value
        case "ALBUM": album = album ?? value
        case "ALBUMARTIST", "ALBUM ARTIST": albumArtist = albumArtist ?? value
        case "GENRE": genre = genre ?? value
        case "DATE", "YEAR": year = year ?? value
        case "TRACKNUMBER":
            let (n, c) = AudioTags.pair(slashed: value)
            trackNumber = trackNumber ?? n; trackCount = trackCount ?? c
        case "TRACKTOTAL", "TOTALTRACKS": trackCount = trackCount ?? Int(value)
        case "DISCNUMBER":
            let (n, c) = AudioTags.pair(slashed: value)
            discNumber = discNumber ?? n; discCount = discCount ?? c
        case "DISCTOTAL", "TOTALDISCS": discCount = discCount ?? Int(value)
        case "COMPOSER": composer = composer ?? value
        case "COMMENT", "DESCRIPTION": comment = comment ?? value
        case "COPYRIGHT": copyright = copyright ?? value
        default: break
        }
    }
}

// MARK: - WAV (RIFF LIST/INFO chunk)

enum RIFFInfo {
    private static let fields: [(String, WritableKeyPath<AudioTags, String?>)] = [
        ("INAM", \.title), ("IART", \.artist), ("IPRD", \.album), ("IGNR", \.genre),
        ("ICRD", \.year), ("ICMT", \.comment), ("ICOP", \.copyright), ("IMUS", \.composer),
    ]

    static func read(_ url: URL) throws -> AudioTags {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var tags = AudioTags()
        guard data.count >= 12, [UInt8](data.prefix(4)) == Array("RIFF".utf8) else { return tags }
        var pos = 12
        while pos + 8 <= data.count {
            let id = String(decoding: data[pos ..< pos + 4], as: UTF8.self)
            var r = ByteReader(data.subdata(in: pos + 4 ..< pos + 8))
            let len = r.le32()
            let body = pos + 8
            guard body + len <= data.count else { break }
            if id == "LIST", len >= 4, String(decoding: data[body ..< body + 4], as: UTF8.self) == "INFO" {
                var sub = body + 4
                while sub + 8 <= body + len {
                    let key = String(decoding: data[sub ..< sub + 4], as: UTF8.self)
                    var lr = ByteReader(data.subdata(in: sub + 4 ..< sub + 8))
                    let n = lr.le32()
                    guard sub + 8 + n <= body + len else { break }
                    let value = String(decoding: data[sub + 8 ..< sub + 8 + n], as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
                    if !value.isEmpty {
                        if let field = fields.first(where: { $0.0 == key })?.1, tags[keyPath: field] == nil {
                            tags[keyPath: field] = value
                        } else if key == "ITRK" {
                            (tags.trackNumber, tags.trackCount) = AudioTags.pair(slashed: value)
                        }
                    }
                    sub += 8 + n + (n & 1)
                }
            }
            pos = body + len + (len & 1)
        }
        return tags
    }

    /// Appends a LIST/INFO chunk and fixes up the RIFF size.
    static func write(_ tags: AudioTags, to url: URL) throws {
        var entries = fields.compactMap { key, field in tags[keyPath: field].map { (key, $0) } }
        if let n = tags.trackNumber { entries.append(("ITRK", tags.trackCount.map { "\(n)/\($0)" } ?? "\(n)")) }
        guard !entries.isEmpty else { return }

        var list = ByteWriter()
        list.data(Data("INFO".utf8))
        for (key, value) in entries {
            let v = Data(value.utf8) + [0]
            list.data(Data(key.utf8)); list.le32(v.count); list.data(v)
            if v.count & 1 == 1 { list.data(Data([0])) }
        }

        var data = try Data(contentsOf: url)
        guard data.count >= 12, [UInt8](data.prefix(4)) == Array("RIFF".utf8) else { return }
        if data.count & 1 == 1 { data.append(0) }
        var chunk = ByteWriter()
        chunk.data(Data("LIST".utf8)); chunk.le32(list.out.count); chunk.data(list.out)
        data.append(chunk.out)
        var size = ByteWriter(); size.le32(data.count - 8)
        data.replaceSubrange(4 ..< 8, with: size.out)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Byte helpers

private struct ByteReader {
    private let bytes: [UInt8]
    private var pos = 0
    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func le32() -> Int {
        guard pos + 4 <= bytes.count else { pos = bytes.count; return 0 }
        defer { pos += 4 }
        return Int(bytes[pos]) | Int(bytes[pos + 1]) << 8 | Int(bytes[pos + 2]) << 16 | Int(bytes[pos + 3]) << 24
    }

    mutating func be32() -> Int {
        guard pos + 4 <= bytes.count else { pos = bytes.count; return 0 }
        defer { pos += 4 }
        return Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
    }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, pos + n <= bytes.count else { pos = bytes.count; return nil }
        defer { pos += n }
        return Data(bytes[pos ..< pos + n])
    }

    mutating func string(_ n: Int) -> String? { bytes(n).map { String(decoding: $0, as: UTF8.self) } }
}

private struct ByteWriter {
    var out = Data()
    mutating func data(_ d: Data) { out.append(d) }
    mutating func le32(_ v: Int) {
        out.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)])
    }
    mutating func be32(_ v: Int) {
        out.append(contentsOf: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }
}

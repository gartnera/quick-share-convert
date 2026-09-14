import Foundation

public extension Preset {
    /// The built-in preset catalog. First group is Instagram; new families
    /// (TikTok, YouTube Shorts, ...) can be added here later.
    static let all: [Preset] = instagram

    static func preset(withID id: String) -> Preset? {
        all.first { $0.id == id }
    }

    /// Instagram-oriented aspect presets. Resolution, frame rate, and bitrate are
    /// chosen separately at convert time; every output is H.264 + AAC in an MP4,
    /// SDR (Rec.709) with HDR always tone-mapped away.
    ///
    /// Framing follows the "per-preset mix" rule: fixed-frame formats
    /// (Reels/Stories, Square) crop to fill; flexible feed formats fit.
    static let instagram: [Preset] = [
        Preset(id: "ig.reels", name: "Reels / Stories", symbol: "rectangle.ratio.9.to.16",
               aspectWidth: 9, aspectHeight: 16, framing: .fill),
        Preset(id: "ig.feed.portrait", name: "Feed Portrait", symbol: "rectangle.ratio.3.to.4",
               aspectWidth: 4, aspectHeight: 5, framing: .fit),
        Preset(id: "ig.square", name: "Square", symbol: "square",
               aspectWidth: 1, aspectHeight: 1, framing: .fill),
        Preset(id: "ig.feed.landscape", name: "Feed Landscape", symbol: "rectangle.ratio.16.to.9",
               aspectWidth: 16, aspectHeight: 9, framing: .fit),
    ]
}

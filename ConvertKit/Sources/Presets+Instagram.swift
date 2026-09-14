import Foundation

public extension Preset {
    /// The built-in preset catalog. First group is Instagram; new families
    /// (TikTok, YouTube Shorts, ...) can be added here later.
    static let all: [Preset] = instagram

    static func preset(withID id: String) -> Preset? {
        all.first { $0.id == id }
    }

    /// Instagram-oriented presets. All target H.264 + AAC in an MP4, SDR
    /// (Rec.709) with HDR always tone-mapped away by the converter.
    ///
    /// Framing choices follow the "per-preset mix" rule: fixed-frame formats
    /// (Reels/Stories, Square) crop to fill; flexible feed formats fit so no
    /// content is lost.
    static let instagram: [Preset] = [
        Preset(
            id: "ig.reels",
            name: "Reels / Stories",
            subtitle: "1080×1920 · 9:16 · cropped",
            symbol: "rectangle.ratio.9.to.16",
            width: 1080, height: 1920, framing: .fill,
            maxFrameRate: 30, videoBitrate: 8_000_000
        ),
        Preset(
            id: "ig.feed.portrait",
            name: "Feed Portrait",
            subtitle: "up to 1080×1350 · 4:5 · fit",
            symbol: "rectangle.ratio.3.to.4",
            width: 1080, height: 1350, framing: .fit,
            maxFrameRate: 30, videoBitrate: 6_000_000
        ),
        Preset(
            id: "ig.square",
            name: "Square",
            subtitle: "1080×1080 · 1:1 · cropped",
            symbol: "square",
            width: 1080, height: 1080, framing: .fill,
            maxFrameRate: 30, videoBitrate: 6_000_000
        ),
        Preset(
            id: "ig.feed.landscape",
            name: "Feed Landscape",
            subtitle: "up to 1920×1080 · 16:9 · fit",
            symbol: "rectangle.ratio.16.to.9",
            width: 1920, height: 1080, framing: .fit,
            maxFrameRate: 30, videoBitrate: 8_000_000
        ),
    ]
}

# Quick Share Convert

Convert videos, photos, and audio straight from the iOS share sheet (or pick
from Photos / Files in the app). Share a file → pick options → the converted
file pops the system share sheet for its final destination.

- **Video**: Instagram aspect presets, H.264/AAC MP4, HDR always stripped
  (tone-mapped to SDR / Rec.709).
- **Photo**: keeps its aspect; converts to JPEG/HEIC with a size cap and
  quality, HDR stripped, metadata kept.
- **Audio**: converts to AAC, ALAC, FLAC, or WAV, keeping song tags + cover art.

The engine and UI are structured so a macOS app is a thin addition later.
Requires iOS 26 / macOS 26.

## Flow

```
Any app (Photos/Files/…)                Quick Share Convert app
   share sheet                              (does the heavy work)
        │                                        │
        ▼                                        ▼
  ShareExtension  ──move file to App Group───►  reads ConversionJob
  pick options       write ConversionJob        MediaConverter → Video/Photo/
  (per media kind)   open quickshareconvert://    AudioConverter, progress UI
        └───────────────────────────────────►   final UIActivityViewController
```

The conversion runs in the **main app**, not the extension, so it isn't bound by
the extension's ~120 MB memory cap.

## Layout

| Path | What |
|------|------|
| `ConvertKit/Sources` | Portable core: `ConversionJob` + `ConversionSettings` (per media kind), `MediaConverter` (dispatch + kind detection), `VideoConverter`, `PhotoConverter`, `AudioConverter`, `AudioTags` (tag passthrough), `Preset`, `TargetOptions`, `VideoLayout` (pure fit/fill/orientation/no-upscale math), `AppGroup`. No UIKit — reused by iOS today, macOS later. |
| `QuickShareConvert/` | iOS app: picks up the job, converts with progress, presents the share sheet. Also picks from Photos (videos/photos) or Files (anything, e.g. downloaded audio). |
| `Shared/` | `ImportModel` (import into the App Group) + `ConfigView` (the options popup), compiled into both the app and the extension. |
| `ShareExtension/` | iOS share extension: activates for one video, image, or audio file; options picker (gated by the source) + hand-off. |
| `ConvertKitTests/` | Unit tests (layout math, presets, job) + integration tests (real conversions of synthesized clips, images, and audio). |
| `project.yml` | XcodeGen spec — the `.xcodeproj` is generated, not committed. |
| `Package.swift` | Same core as a Swift package so `swift test` runs the engine natively on macOS (no simulator needed). |

## Video: presets, resolution & frame rate

A **preset** is the output *shape* (aspect + framing); the user then picks a
**resolution** and **frame rate**. All output is H.264 + AAC in an MP4, SDR
(Rec.709), HDR always stripped.

| Preset (Instagram) | Aspect | Framing |
|--------------------|--------|---------|
| Reels / Stories | 9:16 | fill (crop) |
| Feed Portrait | 4:5 | fit |
| Square | 1:1 | fill (crop) |
| Feed Landscape | 16:9 | fit |

- **Resolution**: 1080p / 2K (1440) / 4K (2160), where the number is the frame's
  short edge. Tiers that would **upscale** the source are disabled; the converter
  never upscales (a "1080p" pick on a smaller clip caps at the source).
- **Frame rate**: 30 / 60. 60 is offered only when the source actually has ≥50fps.
  When the source rate is kept (not reduced), its exact cadence is preserved
  (29.97 stays 29.97 rather than being resampled to 30).
- **Bitrate**: taken from a resolution+fps table (`Bitrate`) for the tier's
  16:9 frame, **scaled to the output's real pixel area** (a 1:1 square gets 9/16
  of the 16:9 budget), then **clamped to the source's data rate** so a low-bitrate
  clip isn't re-inflated. HEVC sources get a 1.5× wider cap, since H.264 needs
  more bits than HEVC for the same quality.
- **Encoder**: H.264 High profile, B-frames on, closed GOP ≤ 2 s, expected
  frame rate hinted to the encoder (required with an auto level / 60fps).
- **Audio**: AAC 128 kbps. Sample rate follows the source when it's 44.1 or
  48 kHz (else 48 kHz); mono stays mono, anything else becomes stereo.

Edit the aspect catalog in `ConvertKit/Sources/Presets+Instagram.swift` and the
resolution/bitrate tables in `ConvertKit/Sources/TargetOptions.swift`.

## Photo

The photo keeps its own aspect — this is format conversion + compression.

- **Format**: JPEG or HEIC (HEIC only where the device has an encoder).
- **Size**: Original, or a cap on the **long edge** (4K = 4096, 2K = 2048, 1080).
  Caps that wouldn't shrink the photo are disabled. Defaults to 4K.
- **Quality**: High / Medium / Low (0.85 / 0.7 / 0.5).
- Orientation is baked into the pixels; HDR / gain maps are dropped (8-bit SDR;
  Display P3 is kept, extended-range/HDR spaces fall back to sRGB); transparency
  is flattened onto white.
- **Metadata passes through** (EXIF, TIFF, GPS, IPTC — date, location, camera),
  with orientation reset and EXIF dimensions updated. Apple's maker note is
  dropped (it only carries gain-map hints).

## Audio

Input is anything Core Audio decodes (MP3, AAC/M4A, WAV, AIFF, CAF, FLAC, ALAC…),
typically downloaded files shared from the Files app.

| Codec | Container | Notes |
|-------|-----------|-------|
| AAC | .m4a | 128 / 192 / 256 kbps; 44.1/48 kHz, mono or stereo (same rules as video audio). Defaults to the lowest tier ≥ a lossy source's rate. |
| ALAC | .m4a | lossless, keeps source sample rate + channels |
| FLAC | .flac | lossless, keeps source sample rate + channels |
| WAV | .wav | 16-bit PCM (24-bit for >16-bit sources) |

No MP3/Opus output — Apple platforms don't ship those encoders. The UI warns
when converting a lossy source to a lossless codec.

**Tags + cover art pass through** (`AudioTags`): read from ID3 / iTunes /
QuickTime metadata (AVFoundation), FLAC Vorbis comments, or WAV RIFF INFO, then
written as iTunes atoms for M4A (passthrough remux), Vorbis comment + PICTURE
blocks for FLAC, and a `LIST/INFO` chunk for WAV (which has no album artist,
disc, or artwork fields). Core Audio's own tag API only writes CAF, hence the
hand-rolled FLAC/WAV writers.

## Build & run

Requires Xcode 26+ and [XcodeGen](https://github.com/yonwoo9/XcodeGen)
(`brew install xcodegen`).

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your DEVELOPMENT_TEAM
xcodegen generate                                        # generate the .xcodeproj
open QuickShareConvert.xcodeproj
```

Then run on a **real device** — the share sheet and re-sharing are best exercised
on device (a simulator runtime isn't needed for the tests below).

### Signing is abstracted — one file per developer

Team ID and bundle prefix are **not** in the repo. They live in a single
git-ignored `Config/Local.xcconfig`; `Config/Base.xcconfig` optionally includes
it and defines defaults. Everything downstream is derived:

- bundle ids → `$(BUNDLE_ID_PREFIX).quickshareconvert[.ShareExtension|.ConvertKit]`
- App Group → `group.$(BUNDLE_ID_PREFIX).quickshareconvert` (in both
  `.entitlements` files and injected into Info.plist as `AppGroupIdentifier`,
  which `AppGroup.identifier` reads at runtime)

So a new contributor sets `DEVELOPMENT_TEAM` (and optionally `BUNDLE_ID_PREFIX`)
once, and **automatic signing** provisions the certs, profiles, and the App Group
capability. Nothing else to edit. CI builds without signing via
`CODE_SIGNING_ALLOWED=NO`.

## Tests

The engine and its tests build for macOS, so they run without a simulator:

```sh
swift test          # 57 tests: layout/gating math, models, real video/photo/audio conversions + tag round-trips
```

`swift test` synthesizes short clips on the fly (`TestVideoFactory`) and asserts
output dimensions, H.264 codec, Rec.709 tagging (HDR-strip guard), and progress.

For the app/extension bundles (UIKit), build the iOS targets:

```sh
xcodebuild -project QuickShareConvert.xcodeproj -scheme QuickShareConvert \
  -sdk iphoneos -configuration Debug build
```

## macOS roadmap

The core (`ConvertKit`) is already cross-platform (AVFoundation + CoreGraphics,
no UIKit). To add macOS: add `macOS` app + `Action`/`Share` app-extension targets
in `project.yml` reusing `ConvertKit`, and swap the two UIKit glue points
(`ShareSheet` → `NSSharingServicePicker`, the responder-chain app launch → a
macOS URL open). No engine changes expected.

## Known caveats

- HDR stripping is verified in tests only by output color tagging; validate with
  real 10-bit HLG/PQ footage on device.
- Re-presenting the system share sheet is done from the main app (reliable),
  which is why the extension hands off rather than sharing inline.

---
🤖 Generated with [Claude Code](https://claude.com/claude-code)

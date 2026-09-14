# Quick Share Convert

Convert videos to platform-ready presets straight from the iOS share sheet.
Share a video → pick a preset → the converted file pops the system share sheet
for its final destination. HDR is always stripped (tone-mapped to SDR / Rec.709).

Starts with **Instagram** presets; the engine and UI are structured so a macOS
app is a thin addition later.

## Flow

```
Any app (Photos/Files/…)                Quick Share Convert app
   share sheet                              (does the heavy work)
        │                                        │
        ▼                                        ▼
  ShareExtension  ──copy video to App Group──►  reads ConversionJob
  pick format +      write ConversionJob        VideoConverter → H.264/AAC, SDR
  resolution + fps   open quickshareconvert://   progress UI
        └───────────────────────────────────►   final UIActivityViewController
```

The conversion runs in the **main app**, not the extension, so it isn't bound by
the extension's ~120 MB memory cap.

## Layout

| Path | What |
|------|------|
| `ConvertKit/Sources` | Portable core: `Preset`, `TargetOptions` (resolution/frame-rate/bitrate), `VideoConverter`, `VideoLayout` (pure fit/fill/orientation/no-upscale math), `ConversionJob`, `AppGroup`. No UIKit — reused by iOS today, macOS later. |
| `QuickShareConvert/` | iOS app: picks up the job, converts with progress, presents the share sheet. |
| `ShareExtension/` | iOS share extension: format + resolution/fps picker (gated by the source) + hand-off. |
| `ConvertKitTests/` | Unit tests (layout math, presets, job) + integration tests (real transcode of a synthesized clip). |
| `project.yml` | XcodeGen spec — the `.xcodeproj` is generated, not committed. |
| `Package.swift` | Same core as a Swift package so `swift test` runs the engine natively on macOS (no simulator needed). |

## Presets, resolution & frame rate

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
swift test          # 33 tests: layout/gating math, preset/job/options models, real transcodes
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

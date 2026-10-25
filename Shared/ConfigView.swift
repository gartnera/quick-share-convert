import ConvertKit
import SwiftUI

// ImportModel lives in Shared/ImportModel.swift.

/// The conversion setup popup. Shows the options for the imported file's kind:
/// - video: format (aspect), resolution, frame rate
/// - photo: format, size cap, quality (aspect is kept)
/// - audio: codec, and bitrate for AAC
///
/// If the file is still importing, options are enabled optimistically and
/// tightened once the source is known; options the source can't satisfy
/// (upscaling, inventing frames) are shown but disabled.
struct ConfigView: View {
    @ObservedObject var model: ImportModel
    var onConvert: (ConversionSettings) -> Void
    var onCancel: () -> Void

    // Video
    @State private var preset: Preset = Preset.all[0]
    @State private var resolution: TargetResolution = .fhd
    @State private var frameRate: TargetFrameRate = .fps30
    // Photo
    @State private var photo = PhotoOptions(size: .large)
    // Audio
    @State private var audio = AudioOptions()

    @State private var convertRequested = false
    @State private var showError = false
    @State private var appliedDefaults = false

    private var isImporting: Bool { model.state == .importing }

    private var videoSource: SourceInfo? {
        if case .video(let s) = model.source { return s } else { return nil }
    }
    private var photoSource: PhotoInfo? {
        if case .photo(let s) = model.source { return s } else { return nil }
    }
    private var audioSource: AudioInfo? {
        if case .audio(let s) = model.source { return s } else { return nil }
    }

    private var availableResolutions: [TargetResolution] {
        videoSource?.availableResolutions(for: preset) ?? TargetResolution.allCases
    }
    private var supports60: Bool { videoSource?.supports60fps ?? true }
    private var availablePhotoSizes: [PhotoSize] { photoSource?.availableSizes() ?? PhotoSize.allCases }

    private var settings: ConversionSettings? {
        switch model.kind {
        case .video?: return .video(presetID: preset.id, resolution: resolution, frameRate: frameRate)
        case .photo?: return .photo(photo)
        case .audio?: return .audio(audio)
        case nil: return nil
        }
    }

    var body: some View {
        container
        // The import may already have failed (e.g. an unsupported file) before
        // this view appeared, when onChange can't see it.
        .onAppear { applyDefaultsIfNeeded(); tryConvert() }
        .onChange(of: model.state) { _, _ in applyDefaultsIfNeeded(); tightenForSource(); tryConvert() }
        .onChange(of: model.source) { _, _ in applyDefaultsIfNeeded(); tightenForSource() }
        .alert("Couldn’t read the file", isPresented: $showError) {
            Button("Close", role: .cancel) { onCancel() }
        } message: {
            if case .failed(let m) = model.state { Text(m) }
        }
    }

    private var form: some View {
        Form {
            switch model.kind {
            case .video?: videoSections
            case .photo?: photoSections
            case .audio?: audioSections
            case nil: EmptyView() // unsupported file; the error alert explains
            }
        }
    }

    #if os(macOS)
    /// macOS has no navigation bar here (and an extension panel has no window
    /// toolbar), so the actions sit in a bottom bar like a dialog's.
    private var container: some View {
        VStack(spacing: 0) {
            form.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                convertButton
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
    #else
    private var container: some View {
        NavigationStack {
            form
                .navigationTitle("Convert")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                    ToolbarItem(placement: .confirmationAction) { convertButton }
                }
        }
    }
    #endif

    // MARK: - Video

    @ViewBuilder private var videoSections: some View {
        Section("Format") {
            ForEach(Preset.all) { p in
                Button { preset = p; clampResolution() } label: { formatRow(p) }
                    .buttonStyle(.plain)
            }
        }

        Section("Resolution") {
            SegmentedOptions(
                options: TargetResolution.allCases,
                selection: $resolution,
                isEnabled: { availableResolutions.contains($0) },
                label: { $0.label }
            )
        }

        Section("Frame rate") {
            SegmentedOptions(
                options: TargetFrameRate.allCases,
                selection: $frameRate,
                isEnabled: { $0 == .fps30 || supports60 },
                label: { "\($0.label) fps" }
            )
        }

        sourceSection(
            videoSource.map { "\(Int($0.orientedSize.width))×\(Int($0.orientedSize.height)) · \(fpsText($0.nominalFrameRate)) fps" },
            reading: "Reading video…",
            note: "HDR is always stripped · exports H.264 · bitrate capped to the source"
        )
    }

    private func formatRow(_ p: Preset) -> some View {
        HStack(spacing: 14) {
            Image(systemName: p.symbol)
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.body.weight(.medium))
                Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if p == preset {
                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Photo

    @ViewBuilder private var photoSections: some View {
        Section("Format") {
            SegmentedOptions(options: PhotoFormat.allCases, selection: $photo.format,
                             isEnabled: { $0.isEncodable }, label: { $0.label })
        }

        Section {
            SegmentedOptions(options: PhotoSize.allCases, selection: $photo.size,
                             isEnabled: { availablePhotoSizes.contains($0) }, label: { $0.label })
        } header: {
            Text("Size")
        } footer: {
            Text("Longest edge. The photo keeps its own aspect and is never upscaled.")
        }

        Section("Quality") {
            SegmentedOptions(options: PhotoQuality.allCases, selection: $photo.quality,
                             isEnabled: { _ in true }, label: { $0.label })
        }

        sourceSection(
            photoSource.map { s in
                ["\(Int(s.orientedSize.width))×\(Int(s.orientedSize.height))", s.formatName]
                    .compactMap { $0 }.joined(separator: " · ")
            },
            reading: "Reading photo…",
            note: "HDR is stripped · metadata (date, location, camera) is kept"
        )
    }

    // MARK: - Audio

    @ViewBuilder private var audioSections: some View {
        Section("Codec") {
            SegmentedOptions(options: AudioCodec.allCases, selection: $audio.codec,
                             isEnabled: { _ in true }, label: { $0.label })
        }

        if audio.codec.isLossy {
            Section("Bitrate") {
                SegmentedOptions(options: AudioBitrate.allCases, selection: $audio.bitrate,
                                 isEnabled: { _ in true }, label: { $0.label })
            }
        }

        sourceSection(
            audioSource.map { s in
                [s.codecName, kHzText(s.sampleRate), channelText(s.channels), durationText(s.duration)]
                    .joined(separator: " · ")
            },
            reading: "Reading audio…",
            note: audioNote
        )
    }

    private var audioNote: String {
        if audio.codec.isLossy { return "AAC in .m4a — plays everywhere" }
        if let s = audioSource, !s.isLossless {
            return "The source is lossy (\(s.codecName)), so lossless output only makes a bigger file, not a better one."
        }
        return "Lossless · keeps the source’s sample rate and channels"
    }

    // MARK: - Shared

    private func sourceSection(_ description: String?, reading: String, note: String) -> some View {
        Section {
            if let description {
                LabeledContent("Source") {
                    Text(description).foregroundStyle(.secondary)
                }
            } else if isImporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(reading).foregroundStyle(.secondary)
                }
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var convertButton: some View {
        if convertRequested && isImporting {
            HStack(spacing: 6) { ProgressView(); Text("Preparing…") }
        } else {
            Button("Convert") {
                convertRequested = true
                tryConvert()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Once we requested a convert, fire it as soon as the import is ready (or
    /// surface a failure).
    private func tryConvert() {
        if case .failed = model.state { showError = true; return }
        guard convertRequested, model.state == .ready, let settings else { return } // else "Preparing…"
        onConvert(settings)
    }

    /// Once the source is known, default to its native export: for video the
    /// highest non-upscaling resolution and frame rate (a 4K60 clip defaults to
    /// 4K · 60); for photos the 4K cap (or Original if already smaller); for
    /// AAC the tier matching a lossy source. Runs once; the user can change it.
    private func applyDefaultsIfNeeded() {
        guard !appliedDefaults, let source = model.source else { return }
        switch source {
        case .video:
            resolution = availableResolutions.last ?? .fhd
            frameRate = supports60 ? .fps60 : .fps30
        case .photo:
            photo.size = availablePhotoSizes.contains(.large) ? .large : .original
        case .audio(let s):
            audio.bitrate = s.suggestedBitrate
        }
        appliedDefaults = true
    }

    /// When the real source becomes known, drop any now-invalid selection.
    private func tightenForSource() {
        clampResolution()
        if !supports60, frameRate == .fps60 { frameRate = .fps30 }
        if !availablePhotoSizes.contains(photo.size) { photo.size = .original }
        if !photo.format.isEncodable { photo.format = .jpeg }
    }

    private func clampResolution() {
        if !availableResolutions.contains(resolution) {
            resolution = availableResolutions.last ?? .fhd
        }
    }

    private func fpsText(_ rate: Float) -> String {
        let rounded = rate.rounded()
        return abs(rate - rounded) < 0.05 ? String(Int(rounded)) : String(format: "%.2f", rate)
    }

    private func kHzText(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    private func channelText(_ channels: Int) -> String {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        default: return "\(channels) ch"
        }
    }

    private func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A segmented control that renders every option but disables the ones that
/// `isEnabled` rejects (so the user can see, but not pick, unavailable choices).
private struct SegmentedOptions<Option: Identifiable & Equatable>: View {
    let options: [Option]
    @Binding var selection: Option
    let isEnabled: (Option) -> Bool
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options) { option in
                let enabled = isEnabled(option)
                let selected = option == selection
                Button {
                    if enabled { selection = option }
                } label: {
                    Text(label(option))
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selected ? Color.accentColor : Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(selected ? Color.white : (enabled ? Color.primary : Color.secondary))
                        .opacity(enabled ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

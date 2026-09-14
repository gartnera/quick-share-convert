import ConvertKit
import SwiftUI

/// The share-extension screen: choose a format (aspect), a resolution, and a
/// frame rate, then convert. The screen appears instantly; while the video is
/// still importing in the background, options are enabled optimistically and
/// tightened once the source is known. Options the source can't satisfy
/// (upscaling or inventing frames) are shown but disabled.
struct ConfigView: View {
    @ObservedObject var model: ImportModel
    var onConvert: (Preset, TargetResolution, TargetFrameRate) -> Void
    var onCancel: () -> Void

    @State private var preset: Preset = Preset.all[0]
    @State private var resolution: TargetResolution = .fhd
    @State private var frameRate: TargetFrameRate = .fps30
    @State private var convertRequested = false
    @State private var showError = false

    private var availableResolutions: [TargetResolution] {
        model.source?.availableResolutions(for: preset) ?? TargetResolution.allCases
    }
    private var supports60: Bool { model.source?.supports60fps ?? true }
    private var isImporting: Bool { model.state == .importing }

    var body: some View {
        NavigationStack {
            Form {
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

                Section {
                    if let s = model.source {
                        LabeledContent("Source") {
                            Text("\(Int(s.orientedSize.width))×\(Int(s.orientedSize.height)) · \(fpsText(s.nominalFrameRate)) fps")
                                .foregroundStyle(.secondary)
                        }
                    } else if isImporting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading video…").foregroundStyle(.secondary)
                        }
                    }
                    Text("HDR is always stripped · exports H.264 · bitrate capped to the source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Convert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { convertButton }
            }
        }
        .onChange(of: model.state) { _, _ in tightenForSource(); tryConvert() }
        .onChange(of: model.source) { _, _ in tightenForSource() }
        .alert("Couldn’t read the video", isPresented: $showError) {
            Button("Close", role: .cancel) { onCancel() }
        } message: {
            if case .failed(let m) = model.state { Text(m) }
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
            .fontWeight(.semibold)
        }
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

    /// Once we requested a convert, fire it as soon as the import is ready (or
    /// surface a failure).
    private func tryConvert() {
        guard convertRequested else { return }
        switch model.state {
        case .ready: onConvert(preset, resolution, frameRate)
        case .failed: showError = true
        case .importing: break // keep waiting; button shows "Preparing…"
        }
    }

    /// When the real source becomes known, drop any now-invalid selection.
    private func tightenForSource() {
        clampResolution()
        if !supports60, frameRate == .fps60 { frameRate = .fps30 }
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

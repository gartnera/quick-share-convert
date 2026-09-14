import ConvertKit
import SwiftUI

/// The share-extension screen: choose a format (aspect), a resolution, and a
/// frame rate, then convert. Options the source can't satisfy (upscaling or
/// inventing frames) are shown but disabled.
struct ConfigView: View {
    let source: SourceInfo
    var onConvert: (Preset, TargetResolution, TargetFrameRate) -> Void
    var onCancel: () -> Void

    @State private var preset: Preset = Preset.all[0]
    @State private var resolution: TargetResolution = .fhd
    @State private var frameRate: TargetFrameRate = .fps30

    private var availableResolutions: [TargetResolution] { source.availableResolutions(for: preset) }

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
                        isEnabled: { $0 == .fps30 || source.supports60fps },
                        label: { "\($0.label) fps" }
                    )
                }

                Section {
                    Text("HDR is always stripped · exports H.264 · bitrate capped to the source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Convert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Convert") { onConvert(preset, resolution, frameRate) }
                        .fontWeight(.semibold)
                }
            }
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

    /// Keep the resolution selection valid when the chosen format changes what the
    /// source can produce.
    private func clampResolution() {
        if !availableResolutions.contains(resolution) {
            resolution = availableResolutions.last ?? .fhd
        }
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

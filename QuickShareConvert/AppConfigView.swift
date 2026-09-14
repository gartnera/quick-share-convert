import ConvertKit
import SwiftUI

/// In-app conversion setup for a video imported via PhotoKit. Shows the detected
/// source (so we can see the true fps from the original) and the format /
/// resolution / frame-rate choices, gated by what the source supports.
struct AppConfigView: View {
    let source: SourceInfo
    var onConvert: (Preset, TargetResolution, TargetFrameRate) -> Void
    var onCancel: () -> Void

    @State private var preset: Preset = Preset.all[0]
    @State private var resolution: TargetResolution = .fhd
    @State private var frameRate: TargetFrameRate = .fps30

    private var availableResolutions: [TargetResolution] { source.availableResolutions(for: preset) }

    var body: some View {
        Form {
            Section("Source (original)") {
                LabeledContent("Detected") {
                    Text("\(Int(source.orientedSize.width))×\(Int(source.orientedSize.height)) · \(fpsText(source.nominalFrameRate)) fps")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Format") {
                ForEach(Preset.all) { p in
                    Button { preset = p; clampResolution() } label: { formatRow(p) }
                        .buttonStyle(.plain)
                }
            }
            Section("Resolution") {
                SegmentedOptions(options: TargetResolution.allCases, selection: $resolution,
                                 isEnabled: { availableResolutions.contains($0) }, label: { $0.label })
            }
            Section("Frame rate") {
                SegmentedOptions(options: TargetFrameRate.allCases, selection: $frameRate,
                                 isEnabled: { $0 == .fps30 || source.supports60fps }, label: { "\($0.label) fps" })
            }
            Section {
                Button {
                    onConvert(preset, resolution, frameRate)
                } label: {
                    Text("Convert").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel", role: .cancel, action: onCancel)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func formatRow(_ p: Preset) -> some View {
        HStack(spacing: 14) {
            Image(systemName: p.symbol).font(.title2).frame(width: 34).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.body.weight(.medium))
                Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if p == preset { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
        }
        .contentShape(Rectangle())
    }

    private func clampResolution() {
        if !availableResolutions.contains(resolution) { resolution = availableResolutions.last ?? .fhd }
    }

    private func fpsText(_ rate: Float) -> String {
        let rounded = rate.rounded()
        return abs(rate - rounded) < 0.05 ? String(Int(rounded)) : String(format: "%.2f", rate)
    }
}

/// Segmented control that shows every option but disables the unavailable ones.
struct SegmentedOptions<Option: Identifiable & Equatable>: View {
    let options: [Option]
    @Binding var selection: Option
    let isEnabled: (Option) -> Bool
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options) { option in
                let enabled = isEnabled(option)
                let selected = option == selection
                Button { if enabled { selection = option } } label: {
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

import ConvertKit
import SwiftUI

/// The one screen the user sees in the share sheet: tap a preset to convert.
struct PresetPickerView: View {
    var onSelect: (Preset) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List(Preset.all) { preset in
                Button {
                    onSelect(preset)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: preset.symbol)
                            .font(.title2)
                            .frame(width: 34)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).font(.body.weight(.medium))
                            Text(preset.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose a preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("HDR is always stripped · exports to H.264")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }
}

import SwiftUI

/// Shown by the share/action extensions when the shared item can't be handed off.
struct FailView: View {
    let message: String
    var onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Close", action: onDismiss).buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

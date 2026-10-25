import SwiftUI

// Conversion status screens, shared by the iOS and macOS apps.

struct ConvertingView: View {
    let title: String?
    let progress: Double

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: progress) {
                Text(title ?? "Finishing up")
                    .font(.headline)
            }
            .progressViewStyle(.linear)
            Text("\(Int(progress * 100))%")
                .font(.title2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct FailedView: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Conversion failed").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}

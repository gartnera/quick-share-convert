import ConvertKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var controller: ConversionController
    @State private var showingShareSheet = false

    var body: some View {
        NavigationStack {
            content
                .padding()
                .navigationTitle("Quick Convert")
                .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: controller.phase) { _, phase in
            if case .finished = phase { showingShareSheet = true }
        }
        .sheet(isPresented: $showingShareSheet, onDismiss: { controller.reset() }) {
            if case .finished(let url) = controller.phase {
                ShareSheet(items: [url]) { showingShareSheet = false }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            HomeView()
        case .converting(let preset, let progress):
            ConvertingView(preset: preset, progress: progress)
        case .finished:
            // Share sheet is presented; keep a light placeholder underneath.
            ConvertingView(preset: nil, progress: 1)
        case .failed(let message):
            FailedView(message: message) { controller.reset() }
        }
    }
}

/// Shown when the app is opened directly (not via a share). Explains the flow
/// and lists the available presets.
private struct HomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Share a video to convert it")
                    .font(.title3.weight(.semibold))
                Text("Open the share sheet on any video, choose **Quick Convert**, pick a preset, and it comes back ready to post — HDR stripped.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Presets").font(.headline)
                ForEach(Preset.all) { preset in
                    HStack(spacing: 12) {
                        Image(systemName: preset.symbol)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 32, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text(preset.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }
}

private struct ConvertingView: View {
    let preset: Preset?
    let progress: Double

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: progress) {
                Text(preset.map { "Converting for \($0.name)" } ?? "Finishing up")
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

private struct FailedView: View {
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

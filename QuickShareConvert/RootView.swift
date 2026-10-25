import ConvertKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var controller: ConversionController
    /// The result being shared, and every result shown but not yet cleaned up.
    /// Tracked per URL because a newer job can finish while an older result's
    /// sheet is still closing (e.g. a result shared back into Quick Convert).
    @State private var shareItem: ShareItem?
    @State private var sharedURLs: Set<URL> = []
    /// True from presenting a share sheet until its onDismiss. A result that
    /// finishes meanwhile is queued: SwiftUI drops a sheet presented while
    /// another is still animating away.
    @State private var shareSheetUp = false
    @State private var queuedShare: URL?

    // In-app import sub-flow (only relevant while idle).
    @StateObject private var importModel = ImportModel()
    @State private var showPicker = false
    @State private var showFileImporter = false
    @State private var showConfig = false

    var body: some View {
        NavigationStack {
            content
                .padding()
                .navigationTitle("Quick Convert")
                .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: controller.phase) { _, phase in
            if case .finished(let url) = phase {
                sharedURLs.insert(url)
                if shareSheetUp { queuedShare = url } else { presentShare(url) }
            }
        }
        .sheet(item: $shareItem, onDismiss: shareSheetDismissed) { item in
            ShareSheet(items: [item.url]) {
                if shareItem == item { shareItem = nil }
            }
        }
        .sheet(isPresented: $showPicker) {
            PhotoPicker(onPick: { provider in
                showPicker = false
                if let provider { importModel.load(from: provider); showConfig = true }
            }, onCancel: { showPicker = false })
            .ignoresSafeArea()
        }
        // Files: mainly for downloaded audio, but takes any supported file.
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio, .movie, .image]) { result in
            if case .success(let url) = result { importModel.load(fileURL: url); showConfig = true }
        }
        // The exact same popup UI the share extension uses.
        .sheet(isPresented: $showConfig) {
            ConfigView(model: importModel,
                       onConvert: { settings in startConvert(settings) },
                       onCancel: { showConfig = false; importModel.discard() })
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            HomeView(onPickPhotos: { showPicker = true }, onPickFile: { showFileImporter = true })
        case .converting(let title, let progress):
            ConvertingView(title: title, progress: progress)
        case .finished:
            ConvertingView(title: nil, progress: 1)
        case .failed(let message):
            FailedView(message: message) { controller.reset() }
        }
    }

    private func presentShare(_ url: URL) {
        shareSheetUp = true
        shareItem = ShareItem(url: url)
    }

    /// Deletes every shown result except a queued one, then presents that.
    private func shareSheetDismissed() {
        shareSheetUp = false
        for url in sharedURLs where url != queuedShare {
            controller.dismissResult(url)
            sharedURLs.remove(url)
        }
        if let next = queuedShare {
            queuedShare = nil
            presentShare(next)
        }
    }

    private func startConvert(_ settings: ConversionSettings) {
        guard let job = importModel.makeJob(settings) else { return }
        showConfig = false
        controller.run(job)
    }
}

/// Shown when the app is opened directly (not via a share). Explains the flow
/// and lists the available video presets.
private struct HomeView: View {
    var onPickPhotos: () -> Void
    var onPickFile: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Convert a video, photo, or audio file")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Pick one here, or share it to **Quick Convert** from any app. Videos come back ready to post, photos compressed, audio in the codec you choose.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button(action: onPickPhotos) {
                    Label("Pick from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: onPickFile) {
                    Label("Pick a file", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Video presets").font(.headline)
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

private struct ShareItem: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}

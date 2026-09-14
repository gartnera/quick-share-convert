import ConvertKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var controller: ConversionController
    @State private var showingShareSheet = false

    // In-app PhotoKit import sub-flow (only relevant while idle).
    @StateObject private var importModel = ImportModel()
    @State private var showPicker = false
    @State private var importing = false
    @State private var showConfig = false
    @State private var importError: String?

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
        .sheet(isPresented: $showPicker) {
            PhotoPicker(onPick: { provider in
                showPicker = false
                if let provider { beginImport(provider) }
            }, onCancel: { showPicker = false })
            .ignoresSafeArea()
        }
        // The exact same popup UI the share extension uses.
        .sheet(isPresented: $showConfig) {
            ConfigView(model: importModel,
                       onConvert: { preset, resolution, frameRate in startConvert(preset, resolution, frameRate) },
                       onCancel: { showConfig = false; discard() })
        }
        .alert("Couldn’t import the video", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            if importing {
                ConvertingView(preset: nil, progress: 0, label: "Reading original…")
            } else {
                HomeView(onPick: { showPicker = true })
            }
        case .converting(let preset, let progress):
            ConvertingView(preset: preset, progress: progress)
        case .finished:
            ConvertingView(preset: nil, progress: 1)
        case .failed(let message):
            FailedView(message: message) { controller.reset() }
        }
    }

    private func beginImport(_ provider: NSItemProvider) {
        importing = true
        Task {
            do {
                let imported = try await PhotoLibraryImport.importOriginal(from: provider)
                await MainActor.run {
                    importModel.inboxFileName = imported.inboxFileName
                    importModel.originalName = imported.originalName
                    importModel.source = imported.source
                    importModel.state = .ready
                    importing = false
                    showConfig = true
                }
            } catch {
                await MainActor.run { importError = error.localizedDescription; importing = false }
            }
        }
    }

    private func startConvert(_ preset: Preset, _ resolution: TargetResolution, _ frameRate: TargetFrameRate) {
        guard let fileName = importModel.inboxFileName else { return }
        let job = ConversionJob(
            sourceFileName: fileName,
            outputBaseName: "\(importModel.originalName)-\(preset.id)",
            presetID: preset.id, resolution: resolution, frameRate: frameRate
        )
        showConfig = false
        controller.run(job)
    }

    private func discard() {
        if let fileName = importModel.inboxFileName,
           let url = AppGroup.inboxURL?.appendingPathComponent(fileName) {
            try? FileManager.default.removeItem(at: url)
        }
        importModel.inboxFileName = nil
    }
}

/// Shown when the app is opened directly (not via a share). Explains the flow
/// and lists the available presets.
private struct HomeView: View {
    var onPick: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Convert a video")
                    .font(.title3.weight(.semibold))
                Text("Pick a video here, or share one to **Quick Convert** from any app. It comes back ready to post — HDR stripped.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: onPick) {
                Label("Pick a video", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
    var label: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if let label, preset == nil, progress == 0 {
                ProgressView()
                Text(label).font(.headline)
            } else {
                ProgressView(value: progress) {
                    Text(preset.map { "Converting for \($0.name)" } ?? "Finishing up")
                        .font(.headline)
                }
                .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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

import AppKit
import ConvertKit
import SwiftUI

struct MacRootView: View {
    @EnvironmentObject private var controller: ConversionController
    @EnvironmentObject private var opener: OpenedFiles

    // In-app import sub-flow (only relevant while idle).
    @StateObject private var importModel = ImportModel()
    @State private var showFileImporter = false
    @State private var showConfig = false
    /// Started once the config sheet has fully closed (same as iOS).
    @State private var jobAfterConfig: ConversionJob?
    @State private var isDropTargeted = false

    private var isIdle: Bool { controller.phase == .idle && !showConfig }

    var body: some View {
        content
            .padding(24)
            .frame(width: 440, height: 420)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard isIdle, let url = urls.first else { return false }
                open(url)
                return true
            } isTargeted: { isDropTargeted = $0 && isIdle }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio, .movie, .image]) { result in
                if case .success(let url) = result { open(url) }
            }
            .sheet(isPresented: $showConfig, onDismiss: configDismissed) {
                ConfigView(model: importModel,
                           onConvert: { settings in startConvert(settings) },
                           onCancel: { showConfig = false })
                    .frame(width: 440, height: 560)
            }
            .onChange(of: controller.phase) { _, phase in
                if case .finished(let url) = phase {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                openPendingFile()
            }
            .onChange(of: opener.file) { _, _ in openPendingFile() }
            .onAppear { openPendingFile() }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            MacHomeView(onPickFile: { showFileImporter = true })
        case .converting(let title, let progress):
            ConvertingView(title: title, progress: progress)
        case .finished(let url):
            MacFinishedView(url: url, onDone: { controller.reset() })
        case .failed(let message):
            FailedView(message: message) { controller.reset() }
        }
    }

    private func open(_ url: URL) {
        importModel.load(fileURL: url)
        showConfig = true
    }

    /// Shows the options for a file opened from Finder, once we're free to.
    private func openPendingFile() {
        guard isIdle, let url = opener.file else { return }
        opener.file = nil
        open(url)
    }

    private func startConvert(_ settings: ConversionSettings) {
        guard let job = importModel.makeJob(settings) else { return }
        jobAfterConfig = job
        showConfig = false
    }

    /// Runs the chosen job, or discards the import if the sheet was cancelled.
    private func configDismissed() {
        if let job = jobAfterConfig {
            jobAfterConfig = nil
            controller.run(job)
        } else {
            importModel.discard()
            openPendingFile()
        }
    }
}

private struct MacHomeView: View {
    var onPickFile: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Convert a video, photo, or audio file")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Drop one here, or in Finder right-click a file › **Quick Actions** or **Share** › **Quick Convert**. Results are saved to Downloads.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: onPickFile) {
                Label("Choose File…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
    }
}

private struct MacFinishedView: View {
    let url: URL
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Saved to Downloads").font(.headline)
            Text(url.lastPathComponent)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                ShareLink(item: url)
            }
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
    }
}

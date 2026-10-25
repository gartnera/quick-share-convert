import ConvertKit
import Foundation
import SwiftUI

/// Drives the app-side of the flow: pick up the pending job written by the share
/// extension, convert with progress, then hand the result to the share sheet.
@MainActor
final class ConversionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case converting(title: String, progress: Double)
        case finished(url: URL)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle

    private let converter: MediaConverter
    /// Takes the converted file from the outbox to where the result should live
    /// and returns its final URL. iOS keeps it in place (the share sheet is the
    /// destination); macOS moves it to Downloads.
    private let deliver: (URL) throws -> URL
    private var isRunning = false

    init(converter: MediaConverter = MediaConverter(), deliver: @escaping (URL) throws -> URL = { $0 }) {
        self.converter = converter
        self.deliver = deliver
    }

    /// Called when the app is opened (by the extension or otherwise). Runs the
    /// pending job if one exists and we aren't already working on it.
    func pickUpPendingJob() {
        guard !isRunning, let job = ConversionJob.readPending() else { return }
        run(job)
    }

    func run(_ job: ConversionJob) {
        let title = job.settings.progressTitle
        isRunning = true
        phase = .converting(title: title, progress: 0)

        Task {
            do {
                let url = try await converter.convert(job: job) { [weak self] p in
                    Task { @MainActor in
                        guard let self, case .converting = self.phase else { return }
                        self.phase = .converting(title: title, progress: p)
                    }
                }
                // Source is no longer needed once converted.
                if let src = job.sourceURL { try? FileManager.default.removeItem(at: src) }
                ConversionJob.clearPending()
                self.phase = .finished(url: try self.deliver(url))
            } catch {
                ConversionJob.clearPending()
                self.phase = .failed(message: error.localizedDescription)
            }
            self.isRunning = false
        }
    }

    /// Clean up a result once its share sheet closes. Only goes idle if that
    /// result is still the current one: a newer job (e.g. the result was shared
    /// back into Quick Convert) may already have finished while the sheet closed.
    func dismissResult(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if phase == .finished(url: url) { phase = .idle }
    }

    /// Back to idle after a failure.
    func reset() {
        phase = .idle
    }
}

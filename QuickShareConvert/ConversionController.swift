import ConvertKit
import Foundation
import SwiftUI

/// Drives the app-side of the flow: pick up the pending job written by the share
/// extension, convert with progress, then hand the result to the share sheet.
@MainActor
final class ConversionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case converting(preset: Preset, progress: Double)
        case finished(url: URL)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle

    private let converter: VideoConverter
    private var isRunning = false

    init(converter: VideoConverter = VideoConverter()) {
        self.converter = converter
    }

    /// Called when the app is opened (by the extension or otherwise). Runs the
    /// pending job if one exists and we aren't already working on it.
    func pickUpPendingJob() {
        guard !isRunning, let job = ConversionJob.readPending() else { return }
        run(job)
    }

    func run(_ job: ConversionJob) {
        guard let preset = job.preset else {
            phase = .failed(message: ConversionError.presetNotFound.localizedDescription)
            return
        }
        isRunning = true
        phase = .converting(preset: preset, progress: 0)

        Task {
            do {
                let url = try await converter.convert(job: job) { [weak self] p in
                    Task { @MainActor in
                        guard let self, case .converting = self.phase else { return }
                        self.phase = .converting(preset: preset, progress: p)
                    }
                }
                // Source is no longer needed once converted.
                if let src = job.sourceURL { try? FileManager.default.removeItem(at: src) }
                ConversionJob.clearPending()
                self.phase = .finished(url: url)
            } catch {
                ConversionJob.clearPending()
                self.phase = .failed(message: error.localizedDescription)
            }
            self.isRunning = false
        }
    }

    /// Reset to idle and clean up the produced file after the share sheet closes.
    func reset() {
        if case .finished(let url) = phase {
            try? FileManager.default.removeItem(at: url)
        }
        phase = .idle
    }
}

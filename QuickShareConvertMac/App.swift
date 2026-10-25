import AppKit
import SwiftUI

@main
struct QuickShareConvertMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A single window: URL / file opens are routed to it by the delegate
        // instead of SwiftUI spawning a new window per event.
        Window("Quick Convert", id: "main") {
            MacRootView()
                .environmentObject(delegate.controller)
                .environmentObject(delegate.opener)
        }
        .windowResizability(.contentSize)
    }
}

/// Receives everything macOS hands the app: `quickshareconvert://convert` from
/// the share/action extensions, and files from Open With or the Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = ConversionController(deliver: Downloads.deliver)
    let opener = OpenedFiles()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.pickUpPendingJob()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                opener.file = url
            } else {
                controller.pickUpPendingJob()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The latest file opened from Finder (Open With / Dock drop), waiting for the
/// window to show its options.
@MainActor
final class OpenedFiles: ObservableObject {
    @Published var file: URL?
}

/// Where finished conversions go on macOS: the user's Downloads folder (the
/// app is sandboxed and only gets a copy of the source, so it can't write next
/// to the original).
enum Downloads {
    static func deliver(_ url: URL) throws -> URL {
        let dir = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: false)
        let dest = uniqueURL(in: dir, name: url.deletingPathExtension().lastPathComponent,
                             ext: url.pathExtension)
        try FileManager.default.moveItem(at: url, to: dest)
        // Inside the sandbox Downloads is a symlink from the app's container;
        // resolve it so Finder shows the real ~/Downloads.
        return dest.resolvingSymlinksInPath()
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`… if taken.
    private static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

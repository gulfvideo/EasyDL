import SwiftUI
import AppKit

@main
struct EasyDLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @State private var queue = DownloadQueue()
    @State private var prefs = Prefs.shared
    @State private var selection: Set<UUID> = []
    @State private var showingAdd = false

    init() { SelfTest.runIfRequested() }

    var body: some Scene {
        // A single Window, not a WindowGroup: one queue is the whole app, and ⌘N should
        // add URLs rather than open a second empty copy of the list.
        Window("EasyDL", id: "main") {
            ContentView(selection: $selection, showingAdd: $showingAdd)
                .environment(queue)
                .environment(prefs)
                .onAppear {
                    AppDelegate.queue = queue
                    // Anything interrupted by the last quit was restored as .queued.
                    // Without this it would sit there saying "Queued" forever, waiting
                    // for a Resume nobody knows to press. Failed items aren't touched.
                    queue.pump()
                }
        }
        .defaultSize(width: 860, height: 460)
        .commands { menus }

        Settings {
            SettingsView()
                .environment(prefs)
                .onDisappear { queue.pump() }   // a fixed tool path may unblock the queue
        }
    }

    /// Acts on the selection, or on the whole queue when nothing is selected.
    private var targets: Set<UUID> {
        selection.isEmpty ? Set(queue.items.map(\.id)) : selection
    }

    @CommandsBuilder
    private var menus: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add URLs…") { showingAdd = true }
                .keyboardShortcut("n")
            Button("Paste URL from Clipboard") {
                if let s = NSPasteboard.general.string(forType: .string) {
                    queue.add(text: s, kind: prefs.defaultKind, quality: prefs.defaultQuality)
                }
            }
            // Deliberately not ⌘V: that must keep working inside the text editor.
            .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Open Downloads Folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: prefs.outputDir))
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Downloads") {
            Button("Resume") { queue.resume(targets) }
                .keyboardShortcut("r")
            Button("Pause") { queue.pause(targets) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Cancel") { queue.cancel(targets) }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Retry") { queue.retry(targets) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Reveal in Finder") { reveal(selection) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(selection.isEmpty)
            Divider()
            Button("Remove from List") { queue.remove(selection) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(selection.isEmpty)
            Button("Clear Completed") { queue.removeFinished() }
        }

        CommandGroup(replacing: .help) {
            Link("Sites yt-dlp Supports",
                 destination: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!)
        }
    }

    private func reveal(_ ids: Set<UUID>) {
        let urls = ids.compactMap { queue.item($0)?.filePath }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: prefs.outputDir))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var queue: DownloadQueue?

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Quitting kills the child processes, so don't let it happen silently mid-download.
    /// Partial files survive, and --continue resumes them next launch.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard let queue = Self.queue, queue.activeCount > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = queue.activeCount == 1
            ? "A download is still in progress."
            : "\(queue.activeCount) downloads are still in progress."
        alert.informativeText = "Quitting stops them. Partial files are kept, and EasyDL picks them up where they left off next time."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        queue.terminateAll()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.queue?.terminateAll()
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(DownloadQueue.self) private var queue
    @Environment(Prefs.self) private var prefs

    @Binding var selection: Set<UUID>
    @Binding var showingAdd: Bool

    @State private var errorItem: DownloadItem?
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            if prefs.ytdlpPath == nil { MissingToolBanner() }
            table
        }
        .frame(minWidth: 720, minHeight: 320)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAdd) { AddSheet() }
        .sheet(item: $errorItem) { ErrorSheet(item: $0) }
        .dropDestination(for: URL.self, action: handleDrop, isTargeted: { isDropTarget = $0 })
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(queue.items, selection: $selection) {
            TableColumn("Title") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).lineLimit(1).truncationMode(.middle)
                    Text(item.url)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 2)
            }
            .width(min: 200, ideal: 320)

            TableColumn("Status") { item in StatusCell(item: item) }
                .width(min: 140, ideal: 190)

            TableColumn("Format") { item in
                Text(item.kind == .audioMP3 ? "MP3" : "MP4 · \(item.quality.label)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Speed") { item in
                Text(item.speed).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("ETA") { item in
                Text(item.eta).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            // Double-click: open the finished file, otherwise show why it isn't finished.
            guard let item = ids.first.flatMap(queue.item) else { return }
            if let path = item.filePath, item.status == .done {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else if item.status == .failed {
                errorItem = item
            }
        }
        .overlay { if queue.items.isEmpty { EmptyState() } }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<UUID>) -> some View {
        if ids.isEmpty {
            Button("Add URLs…") { showingAdd = true }
        } else {
            Button("Resume") { queue.resume(ids) }
            Button("Pause") { queue.pause(ids) }
            Button("Cancel") { queue.cancel(ids) }
            Divider()
            Button("Retry") { queue.retry(ids) }
            Button("Reveal in Finder") { reveal(ids) }
            Button("Copy Link") { copyLinks(ids) }
            if let item = ids.first.flatMap(queue.item), item.status == .failed {
                Button("Show Error…") { errorItem = item }
            }
            Divider()
            Button("Remove from List") { queue.remove(ids) }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { showingAdd = true } label: { Label("Add URLs", systemImage: "plus") }
                .help("Add URLs to the queue (⌘N)")

            Button { queue.resume(targets) } label: { Label("Resume", systemImage: "play.fill") }
                .disabled(targets.isEmpty)
                .help("Resume the selected downloads")

            Button { queue.pause(targets) } label: { Label("Pause", systemImage: "pause.fill") }
                .disabled(targets.isEmpty)
                .help("Pause the selected downloads")

            Button { queue.cancel(targets) } label: { Label("Cancel", systemImage: "xmark") }
                .disabled(targets.isEmpty)
                .help("Stop the selected downloads")

            Spacer()

            Button { reveal(selection) } label: { Label("Reveal", systemImage: "folder") }
                .disabled(selection.isEmpty)
                .help("Reveal in Finder (⇧⌘R)")
        }
    }

    /// Toolbar buttons act on the selection, or on everything when nothing is selected —
    /// the behaviour a Mac user expects from a queue window.
    private var targets: Set<UUID> {
        selection.isEmpty ? Set(queue.items.map(\.id)) : selection
    }

    // MARK: - Actions

    private func handleDrop(_ urls: [URL], _ point: CGPoint) -> Bool {
        let text = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
            .map(\.absoluteString).joined(separator: "\n")
        guard !text.isEmpty else { return false }
        queue.add(text: text, kind: prefs.defaultKind, quality: prefs.defaultQuality)
        return true
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

    private func copyLinks(_ ids: Set<UUID>) {
        let text = ids.compactMap { queue.item($0)?.url }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Cells and small views

private struct StatusCell: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(item.status.label).font(.callout)
                if !item.playlistPosition.isEmpty {
                    Text("· \(item.playlistPosition)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if item.status == .running || item.status == .paused {
                ProgressView(value: min(item.percent, 100), total: 100)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else if item.status == .failed {
                // Without this the only way to reach the reason is a double-click
                // nobody thinks to try.
                Text("Double-click for details")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .foregroundStyle(item.status == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 42)).foregroundStyle(.tertiary)
            Text("No downloads").font(.title3)
            Text("Press ⌘N, or drag a link here from your browser.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .allowsHitTesting(false)
    }
}

private struct MissingToolBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("yt-dlp isn't installed").font(.callout.weight(.medium))
                Text("Run  brew install yt-dlp ffmpeg  in Terminal, then reopen EasyDL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install yt-dlp ffmpeg", forType: .string)
            }
        }
        .padding(10)
        .background(.quaternary)
    }
}

private struct ErrorSheet: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss

    private var text: String { item.log.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download failed").font(.headline)
            Text(item.displayTitle).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)

            if let d = YTDLP.diagnose(item.log) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(d.message).font(.callout)
                        if d.offerFullDiskAccess {
                            Button("Open Full Disk Access Settings…") {
                                NSWorkspace.shared.open(URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            ScrollView {
                Text(text.isEmpty ? "yt-dlp exited without explaining why." : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

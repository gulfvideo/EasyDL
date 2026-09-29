import SwiftUI
import AppKit

/// Paste as many links as you like, one per line. Format and quality are chosen once
/// for the whole batch and can be changed per row later from Settings defaults.
struct AddSheet: View {
    @Environment(DownloadQueue.self) private var queue
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var kind: Kind?
    @State private var quality: Quality?
    @FocusState private var focused: Bool

    private var resolvedKind: Kind { kind ?? prefs.defaultKind }
    private var resolvedQuality: Quality { quality ?? prefs.defaultQuality }

    private var urlCount: Int {
        text.split(whereSeparator: \.isNewline)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("http") }
            .count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Downloads").font(.headline)

            Text("One URL per line. Playlist and channel links are expanded automatically.")
                .font(.callout).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .frame(height: 150)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            HStack(spacing: 16) {
                Picker("Format", selection: Binding(get: { resolvedKind }, set: { kind = $0 })) {
                    ForEach(Kind.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 210)

                Picker("Quality", selection: Binding(get: { resolvedQuality }, set: { quality = $0 })) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 210)
                .disabled(resolvedKind == .audioMP3)
                .help(resolvedKind == .audioMP3 ? "MP3 always uses the best available audio." : "")
            }

            HStack {
                Button("Paste from Clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + s
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(urlCount > 1 ? "Add \(urlCount)" : "Add") {
                    queue.add(text: text, kind: resolvedKind, quality: resolvedQuality)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlCount == 0)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // Pre-fill from the clipboard when it already holds a link — the reason
            // most people open this window in the first place.
            if let s = NSPasteboard.general.string(forType: .string),
               s.hasPrefix("http://") || s.hasPrefix("https://") {
                text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            focused = true
        }
    }
}

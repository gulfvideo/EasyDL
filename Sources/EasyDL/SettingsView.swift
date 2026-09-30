import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Prefs.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs

        TabView {
            Form {
                Section("Save to") {
                    HStack {
                        Text(prefs.outputDir)
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                    Text("Playlists get their own subfolder here. Single videos don't.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show the files in Finder when downloads finish",
                           isOn: $prefs.revealWhenDone)
                    Text("""
                        Opens this folder with the new files selected, once the whole \
                        queue has finished — not once per download. Nothing opens if \
                        everything failed or was cancelled.
                        """)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Defaults for new downloads") {
                    Picker("Format", selection: $prefs.defaultKind) {
                        ForEach(Kind.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Quality", selection: $prefs.defaultQuality) {
                        ForEach(Quality.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section("Finished downloads") {
                    Picker("Clear them", selection: $prefs.cleanupPolicy) {
                        ForEach(CleanupPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    Text("""
                        Only clears the list — the files you downloaded are never touched. \
                        Anything still going or paused is left alone. Downloads ▸ Clear \
                        Completed does the same thing on demand.
                        """)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Queue") {
                    Stepper("Download \(prefs.maxConcurrent) at a time",
                            value: $prefs.maxConcurrent, in: 1...6)
                    Text("Higher isn't always faster — some sites throttle parallel requests.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Cookie file (most reliable)") {
                    HStack {
                        Text(prefs.cookieFile.isEmpty ? "None chosen" : prefs.cookieFile)
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(prefs.cookieFile.isEmpty ? .secondary : .primary)
                        Spacer()
                        if !prefs.cookieFile.isEmpty {
                            Button("Clear") { prefs.cookieFile = "" }
                        }
                        Button("Choose…", action: chooseCookieFile)
                    }
                    Text("""
                        A cookies.txt export. Unlike reading a browser directly, this needs \
                        no macOS privacy grant, survives rebuilds, and isn't invalidated when \
                        the browser rotates your session — which is the usual cause of a \
                        403 Forbidden partway through a download. When set, this is used \
                        instead of the browser below.
                        """)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Or read a browser directly") {
                    Picker("Use cookies from", selection: $prefs.cookieSource) {
                        ForEach(CookieSource.allCases) { Text($0.label).tag($0) }
                    }
                    Text("""
                        Needed for age-restricted, members-only and private videos. \
                        YouTube also refuses many anonymous requests outright with \
                        "Sign in to confirm you're not a bot" — picking your browser here fixes that.
                        """)
                        .font(.caption).foregroundStyle(.secondary)
                    if prefs.cookieSource == .chrome || prefs.cookieSource == .brave
                        || prefs.cookieSource == .edge || prefs.cookieSource == .chromium
                        || prefs.cookieSource == .vivaldi || prefs.cookieSource == .opera {
                        Label("Quit that browser first — Chromium locks its cookie database while running.",
                              systemImage: "info.circle")
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Accounts", systemImage: "person.crop.circle") }

            Form {
                Section("yt-dlp") {
                    ToolRow(name: "yt-dlp", path: prefs.ytdlpPath,
                            version: prefs.ytdlpPath.flatMap { Tools.capture($0, ["--version"]) })
                    TextField("Custom path (optional)", text: $prefs.ytdlpOverride)
                }
                Section("ffmpeg") {
                    ToolRow(name: "ffmpeg", path: prefs.ffmpegPath, version: nil)
                    TextField("Custom path (optional)", text: $prefs.ffmpegOverride)
                    Text("Required to make MP3s and to merge high-quality video with audio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("PO token provider") {
                    ToolRow(name: "bgutil provider", path: prefs.potServerHome, version: nil)
                    TextField("Custom path to .../server (optional)", text: $prefs.potOverride)
                    Text("""
                        Optional. YouTube refuses its audio-only formats with 403 unless \
                        the caller can mint a PO token. With this installed, an MP3 \
                        downloads ~180MB of audio instead of ~1GB of video it throws away. \
                        Install it with ./install-pot-provider.sh; it needs Node.
                        """)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("EasyDL uses the yt-dlp installed on this Mac rather than bundling a copy, so `brew upgrade yt-dlp` is all it takes to keep up with site changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        // Sized for the tallest tab. General grew when the Finder toggle and the
        // cleanup picker were added, and at 400 its Queue section fell off the bottom.
        .frame(width: 540, height: 640)
    }

    private func chooseCookieFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.prompt = "Use"
        panel.message = "Choose a cookies.txt file exported from your browser."
        if panel.runModal() == .OK, let url = panel.url {
            prefs.cookieFile = url.path
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: prefs.outputDir)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            prefs.outputDir = url.path
        }
    }
}

private struct ToolRow: View {
    let name: String
    let path: String?
    let version: String?

    private var notFoundHint: String {
        name.contains("bgutil") ? "Not installed — optional, see below" : "Not found — brew install \(name)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(path == nil ? .red : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(path ?? notFoundHint)
                    .font(.callout).lineLimit(1).truncationMode(.head)
                if let version {
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

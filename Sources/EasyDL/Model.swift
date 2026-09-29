import Foundation

// MARK: - What the user picked

enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
    case videoMP4, audioMP3
    var id: String { rawValue }
    var label: String { self == .videoMP4 ? "Video (MP4)" : "Audio (MP3)" }
}

enum Quality: String, Codable, CaseIterable, Identifiable, Sendable {
    case best, p2160, p1440, p1080, p720, p480, p360
    var id: String { rawValue }

    /// nil means "whatever is best"; otherwise a hard ceiling in pixels.
    var maxHeight: Int? {
        switch self {
        case .best:  return nil
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720:  return 720
        case .p480:  return 480
        case .p360:  return 360
        }
    }

    var label: String { maxHeight.map { "\($0)p" } ?? "Best available" }
}

/// How long finished rows stay in the list. Evaluated once, at launch.
enum CleanupPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case never, onLaunch, afterDay, afterWeek, afterMonth
    var id: String { rawValue }

    var label: String {
        switch self {
        case .never:      return "Keep them"
        case .onLaunch:   return "Every time EasyDL opens"
        case .afterDay:   return "When they're a day old"
        case .afterWeek:  return "When they're a week old"
        case .afterMonth: return "When they're a month old"
        }
    }

    /// nil = keep forever, 0 = drop every finished row, otherwise an age in seconds.
    var maxAge: TimeInterval? {
        switch self {
        case .never:      return nil
        case .onLaunch:   return 0
        case .afterDay:   return 86_400
        case .afterWeek:  return 7 * 86_400
        case .afterMonth: return 30 * 86_400
        }
    }
}

enum Status: String, Codable, Sendable {
    case queued, running, paused, done, failed, canceled

    var label: String {
        switch self {
        case .queued:   return "Queued"
        case .running:  return "Downloading"
        case .paused:   return "Paused"
        case .done:     return "Done"
        case .failed:   return "Failed"
        case .canceled: return "Canceled"
        }
    }

    var isFinished: Bool { self == .done || self == .failed || self == .canceled }
}

// MARK: - A single row in the queue

struct DownloadItem: Identifiable, Codable, Sendable {
    var id = UUID()
    var url: String
    var kind: Kind
    var quality: Quality

    var title: String = ""
    var status: Status = .queued
    var percent: Double = 0          // 0...100, as reported by yt-dlp
    var speed: String = ""
    var eta: String = ""
    var playlistPosition: String = ""   // "3/20" while walking a playlist, else ""
    var filePath: String?
    /// When this row reached a finished state, so age-based cleanup has something to
    /// measure. Rows saved before this existed are stamped on first load.
    var finishedAt: Date?
    /// Set once we've re-run this with a fallback player client after a 403,
    /// so the retry can never loop.
    var triedFallback = false
    var log: [String] = []              // tail of non-progress output, for the error sheet

    /// yt-dlp restarts the percentage for each stream it fetches (video, then audio,
    /// then the merge). Showing its number verbatim is what the CLI does too.
    var displayTitle: String { title.isEmpty ? url : title }

    enum CodingKeys: String, CodingKey {
        case id, url, kind, quality, title, status, percent, speed, eta
        case playlistPosition, filePath, finishedAt, triedFallback, log
    }
}

// Lenient decoding, in an extension so the memberwise init survives.
//
// Swift's synthesized decoder does NOT fall back to a property's default value when
// a key is missing — it throws. Since the queue is persisted across launches, adding
// any field to this struct would make every previously saved queue fail to decode,
// and load()'s `try?` would silently discard the user's whole download list. Only
// `url` is genuinely required.
extension DownloadItem {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url              = try c.decode(String.self, forKey: .url)
        id               = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind             = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .videoMP4
        quality          = try c.decodeIfPresent(Quality.self, forKey: .quality) ?? .best
        title            = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status           = try c.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        percent          = try c.decodeIfPresent(Double.self, forKey: .percent) ?? 0
        speed            = try c.decodeIfPresent(String.self, forKey: .speed) ?? ""
        eta              = try c.decodeIfPresent(String.self, forKey: .eta) ?? ""
        playlistPosition = try c.decodeIfPresent(String.self, forKey: .playlistPosition) ?? ""
        filePath         = try c.decodeIfPresent(String.self, forKey: .filePath)
        finishedAt       = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        triedFallback    = try c.decodeIfPresent(Bool.self, forKey: .triedFallback) ?? false
        log              = try c.decodeIfPresent([String].self, forKey: .log) ?? []
    }
}

// MARK: - Everything needed to build one yt-dlp invocation

struct DownloadSpec: Sendable {
    var url: String
    var kind: Kind
    var quality: Quality
    var outputDir: String
    var cookiesBrowser: String = ""     // "" = don't touch cookies
    var cookieFile: String = ""         // a cookies.txt; wins over cookiesBrowser
    var ffmpegDir: String?
    var concurrentFragments: Int = 4
    /// A YouTube player client to force, used only on the retry after a 403.
    var fallbackClient: String = ""
    /// The bgutil PO token provider's `server` directory, when one is installed.
    var potServerHome: String = ""
}

enum YTDLP {

    /// Markers we prepend so our own lines are unmistakable in yt-dlp's output stream.
    static let progressMarker = "@@P@@"
    static let doneMarker = "@@DONE@@"

    /// Playlist entries land in a folder named after the playlist; single videos land
    /// flat. The `|.` fallback resolves to "./", which the path join swallows — the more
    /// obvious `%(playlist_title&{}/|)s` sanitises its slash into U+29F8 and silently
    /// gives you one long filename instead of a folder.
    ///
    /// SECURITY: the folder name is remote-controlled, and it is a real path component.
    /// yt-dlp replaces "/" in a field value but leaves a lone ".." alone, and its
    /// sanitize_path() does not drop ".." on macOS — so a playlist titled exactly ".."
    /// wrote one level ABOVE the chosen download folder. The bracketed id suffix exists
    /// to stop that: it is emitted whenever playlist_title is present (not when
    /// playlist_id is), so the directory can never be exactly "." or "..", even if the
    /// id is missing or empty. Single videos still collapse to "./".
    static let outputTemplate =
        "%(playlist_title|.)s%(playlist_title& [|)s%(playlist_id|)s%(playlist_title&]|)s/"
        + "%(playlist_index&{:03d} - |)s%(title)s [%(id)s].%(ext)s"

    /// Extensions EasyDL will hand to `NSWorkspace.open`. Everything else is revealed in
    /// the Finder instead.
    ///
    /// SECURITY: the file extension comes from the *server*, not from the user's choice
    /// — yt-dlp derives it from the format it was offered. A hostile URL can therefore
    /// produce a download called `clip.command` or `clip.app`, and opening that executes
    /// it. Files written by yt-dlp carry no quarantine flag, so Gatekeeper would not
    /// warn either. Double-click only opens things that are inert to open.
    static let openableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "mpg", "mpeg", "ts", "m2ts",
        "mp3", "m4a", "aac", "opus", "ogg", "oga", "flac", "wav", "aiff", "wma",
        "jpg", "jpeg", "png", "gif", "webp", "txt", "vtt", "srt", "ass", "pdf",
    ]

    /// True when double-clicking this file should open it rather than reveal it.
    static func isSafeToOpen(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !ext.isEmpty && openableExtensions.contains(ext)
    }

    /// The title and the file path are chosen by the remote server, and they are the
    /// only free-form strings in this line.
    ///
    /// SECURITY: with a plain `s` conversion a newline inside a title passes through
    /// verbatim and splits the output into two lines — so a video titled
    /// "Innocent\n@@DONE@@/somewhere/else.mp4" forges one of our own marker lines and
    /// takes over the file path we later reveal or open. The `j` conversion JSON-encodes
    /// the value, which escapes the newline and quotes the result, so a field can never
    /// become a line. Both are decoded again in the parsers below.
    static let progressTemplate =
        "download:\(progressMarker)%(progress._percent_str)s|%(progress._speed_str)s"
        + "|%(progress._eta_str)s|%(info.playlist_index)s|%(info.n_entries)s|%(info.title)j"

    static func arguments(for spec: DownloadSpec) -> [String] {
        var args = [
            "--ignore-config",        // a GUI must not inherit surprises from ~/.config/yt-dlp
            "--newline",
            "--progress",             // --print implies --quiet, which would hide progress
            "--no-warnings",
            "--continue",             // resume a half-finished file instead of restarting
            // yt-dlp SKIPS unavailable fragments by default and still exits 0, which
            // turns a fragmented download that loses fragments into a short file that
            // looks perfectly valid. Observed: 2352 of 2608 fragments dropped, a 3h50m
            // recording written out as 21 minutes, exit code 0. Fail loudly instead.
            "--abort-on-unavailable-fragments",
            "--progress-template", progressTemplate,
            "--print", "after_move:\(doneMarker)%(filepath)j",
            "--paths", spec.outputDir,
            "-o", outputTemplate,
            "--concurrent-fragments", String(spec.concurrentFragments),
        ]

        if let dir = spec.ffmpegDir {
            args += ["--ffmpeg-location", dir]
        }
        // YouTube's DASH audio-only formats (140, 251) now answer 403 to a full
        // request unless the caller supplies a PO token; a 10 KB range request still
        // succeeds, which is why this looks intermittent. The progressive and HLS
        // formats these clients expose have no such requirement.
        if !spec.fallbackClient.isEmpty {
            args += ["--extractor-args", "youtube:player_client=\(spec.fallbackClient)"]
        }
        // A PO token provider makes YouTube serve the audio-only formats that otherwise
        // answer 403, so MP3 fetches ~180MB of audio instead of ~1GB of video it throws
        // away. Script mode runs the generator on demand — no daemon to supervise.
        // This is a second --extractor-args on purpose: yt-dlp merges repeated ones,
        // and the two keys address different extractors.
        // ";" separates extractor arguments and ":" ends the extractor name, so a path
        // containing either would inject additional arguments into this one string.
        // Everything else travels as its own argv entry and cannot.
        if !spec.potServerHome.isEmpty, !spec.potServerHome.contains(where: { $0 == ";" || $0 == ":" }) {
            args += ["--extractor-args",
                     "youtubepot-bgutilscript:server_home=\(spec.potServerHome)"]
        }
        // A file beats the browser: reading a live browser profile needs a macOS
        // privacy grant that resets whenever the app is rebuilt, and YouTube rotates
        // the session out from under the copy it does manage to take.
        if !spec.cookieFile.isEmpty {
            args += ["--cookies", spec.cookieFile]
        } else if !spec.cookiesBrowser.isEmpty {
            args += ["--cookies-from-browser", spec.cookiesBrowser]
        }

        switch spec.kind {
        case .audioMP3:
            // Normally the audio-only stream: nothing else is downloaded.
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
            if !spec.fallbackClient.isEmpty {
                // No audio-only format survives the fallback, so a combined stream is
                // picked and its video thrown away.
                //
                // "proto" first is the important one: it prefers the single progressive
                // file over the HLS ladder. The fragmented rungs are smaller but drop
                // fragments on long videos (2352 of 2608 lost on a 3h50m recording).
                // Then audio bitrate, so a 3gp rung carrying 24 kbps can't win, then
                // smallest size to break ties.
                args += ["-S", "proto,abr,+size"]
            }
        case .videoMP4:
            if let h = spec.quality.maxHeight {
                // Cap with a filter rather than -S "res:N" — the sort only prefers the
                // closest match and will happily hand you 1080p when you asked for 720p.
                args += ["-f", "bv*[height<=\(h)]+ba/b[height<=\(h)]/bv*+ba/b"]
            } else {
                args += ["-f", "bv*+ba/b"]
            }
            args += ["-S", "ext:mp4:m4a", "--merge-output-format", "mp4"]
        }

        // Belt and braces: extractURLs already requires an http(s) prefix, so a URL can
        // never look like a flag. "--" makes that structural rather than incidental.
        args.append("--")
        args.append(spec.url)
        return args
    }

    /// True when nothing is left to do. Paused counts as unfinished: the user stopped
    /// it deliberately and the batch isn't over, so this must not fire then.
    static func isIdle(_ items: [DownloadItem]) -> Bool {
        !items.contains { $0.status == .running || $0.status == .queued || $0.status == .paused }
    }

    /// Applies the cleanup policy. Unfinished rows are never touched — an interrupted
    /// download is something to resume, not something to tidy away. A finished row with
    /// no timestamp is kept: it predates the field, and `DownloadQueue` stamps it on
    /// load so it ages from that point rather than vanishing immediately.
    static func pruning(_ items: [DownloadItem], policy: CleanupPolicy,
                        now: Date = Date()) -> [DownloadItem] {
        guard let maxAge = policy.maxAge else { return items }
        return items.filter { item in
            guard item.status.isFinished else { return true }
            if maxAge == 0 { return false }
            guard let finished = item.finishedAt else { return true }
            return now.timeIntervalSince(finished) < maxAge
        }
    }

    // MARK: - What the user pasted

    /// Pulls URLs out of whatever lands in the Add sheet, the clipboard or a drop.
    /// People paste one per line, several on a line, a URL with a sentence around it,
    /// or the same link twice — all of which should just work.
    static func extractURLs(from text: String) -> [String] {
        var seen = Set<String>()
        var found: [String] = []

        for var token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            // Strip wrapping a human or a mail client added: <url>, (url), "url", url.
            while let f = token.first, "<([{\"'".contains(f) { token = token.dropFirst() }
            while let l = token.last, ">)]}\"'.,;!".contains(l) { token = token.dropLast() }

            let url = String(token)
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            guard url.count > 8 else { continue }          // "https://" and nothing else
            if seen.insert(url).inserted { found.append(url) }
        }
        return found
    }

    // MARK: - Parsing yt-dlp's chatter back

    struct Progress: Equatable, Sendable {
        var percent: Double?
        var speed: String
        var eta: String
        var playlistPosition: String
        var title: String
    }

    /// Returns nil for any line that isn't one of our progress lines.
    ///
    /// The marker must begin the line: a marker found anywhere would let a field that
    /// merely contains the text "@@P@@" be mistaken for one of our own lines.
    static func parseProgress(_ line: String) -> Progress? {
        guard line.hasPrefix(progressMarker) else { return nil }
        let r = line.startIndex..<line.index(line.startIndex, offsetBy: progressMarker.count)
        // Title is last and may itself contain "|", so cap the split and keep the remainder.
        let fields = line[r.upperBound...].split(separator: "|", maxSplits: 5,
                                                 omittingEmptySubsequences: false)
        guard fields.count == 6 else { return nil }

        let rawPercent = fields[0].trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")

        return Progress(
            percent: Double(rawPercent),
            speed: cleanStat(fields[1]),
            eta: cleanStat(fields[2]),
            playlistPosition: playlistPosition(index: clean(fields[3]), total: clean(fields[4])),
            title: decodeJSON(clean(fields[5]))
        )
    }

    // MARK: - Turning yt-dlp's errors into something actionable

    struct Diagnosis: Equatable, Sendable {
        var message: String
        /// True when the fix is a Full Disk Access grant, so the sheet can offer a
        /// button straight to that System Settings pane.
        var offerFullDiskAccess = false
    }

    /// yt-dlp's failures are mostly a handful of recurring causes wearing different
    /// words. Recognise them so the error sheet says what to do instead of just
    /// what went wrong.
    static func diagnose(_ log: [String]) -> Diagnosis? {
        let text = log.joined(separator: "\n").lowercased()
        guard !text.isEmpty else { return nil }

        if text.contains("binarycookies") && text.contains("not permitted") {
            return Diagnosis(
                message: """
                    macOS blocks apps from reading Safari's cookies unless they have \
                    Full Disk Access. Either grant it to EasyDL below, or switch \
                    Settings ▸ Accounts to a different browser.
                    """,
                offerFullDiskAccess: true)
        }
        if text.contains("could not find") && text.contains("cookies database") {
            return Diagnosis(message: """
                macOS blocked EasyDL from reading that browser's cookie folder. This \
                grant resets every time the app is rebuilt. Use a cookies.txt file \
                under Settings ▸ Accounts instead — it needs no permission at all.
                """)
        }
        if text.contains("could not copy") && text.contains("cookie")
            || text.contains("unable to open database")
            || text.contains("database is locked") {
            return Diagnosis(message: """
                That browser is holding its cookie database open. Quit it completely \
                and retry — Chromium-based browsers lock the file while running.
                """)
        }
        if text.contains("not a bot") || text.contains("sign in to confirm") {
            return Diagnosis(message: """
                The site refused an anonymous request. Pick a browser you're signed \
                in with under Settings ▸ Accounts, then retry.
                """)
        }
        if text.contains("members-only") || text.contains("join this channel")
            || text.contains("private video") || text.contains("login required") {
            return Diagnosis(message: """
                This video needs an account that can see it. Choose a browser signed \
                into that account under Settings ▸ Accounts.
                """)
        }
        if text.contains("ffmpeg") && (text.contains("not found") || text.contains("not installed")) {
            return Diagnosis(message: """
                ffmpeg is missing, and it's required for MP3 and for merging \
                high-quality video. Run  brew install ffmpeg  and retry.
                """)
        }
        if text.contains("video unavailable") || text.contains("removed by the uploader") {
            return Diagnosis(message: "The site says this video isn't available.")
        }
        if text.contains("unavailable fragment") || text.contains("fragments not found")
            || text.contains("giving up after") {
            return Diagnosis(message: """
                The server stopped serving parts of this file partway through, so the \
                download was aborted rather than saved with gaps. Long videos are the \
                usual victims. Retry, or choose MP3, which uses a single-file stream.
                """)
        }
        // 403 on the media URL specifically — the page was readable, the file wasn't.
        // Nearly always a session that moved on after the cookies were copied.
        if text.contains("403") || text.contains("forbidden") {
            return Diagnosis(message: """
                YouTube refused the media file (403) on both the normal and the fallback \
                player client. Its audio-only formats need a PO token this build can't \
                mint. Check your cookie file is current, or try MP4 instead.
                """)
        }
        return nil
    }

    /// A 403 on the media URL, which a different player client can usually dodge.
    static func isForbidden(_ log: [String]) -> Bool {
        let t = log.joined(separator: "\n").lowercased()
        return t.contains("403") || t.contains("forbidden")
    }

    /// Returns the final file path for a completed download, or nil.
    ///
    /// Anchored to the start of the line for the same reason as parseProgress.
    static func parseDone(_ line: String) -> String? {
        guard line.hasPrefix(doneMarker) else { return nil }
        let raw = String(line.dropFirst(doneMarker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = decodeJSON(raw)
        return path.isEmpty ? nil : path
    }

    /// True when `path` is the download folder or something inside it. Both sides are
    /// standardised first so /tmp vs /private/tmp does not read as an escape.
    ///
    /// Defence in depth: the only file path EasyDL acts on comes from yt-dlp's own
    /// output, and --paths already confines it. This means a forged path would still be
    /// ignored rather than revealed or opened.
    static func isInside(_ path: String, directory: String) -> Bool {
        guard !path.isEmpty, !directory.isEmpty else { return false }
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: directory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path == root.path || file.path.hasPrefix(rootPath)
    }

    /// Undoes the `j` conversion. Falls back to the raw text for anything that isn't a
    /// JSON string, so an older yt-dlp that ignored `j` still works.
    static func decodeJSON(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]) as? String
        else { return raw }
        // A decoded title can still hold newlines or other control characters; they are
        // harmless now that they cannot split a line, but they have no business in a
        // one-line table cell either.
        return decoded.filter { !$0.unicodeScalars.contains(where: { u in
            u.properties.generalCategory == .control }) }
    }

    /// yt-dlp writes the string "NA" for fields that don't apply to this download.
    private static func clean(_ s: Substring) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "NA" ? "" : t
    }

    /// Speed and ETA additionally read as "Unknown" / "Unknown B/s" before the first
    /// chunk lands. Kept separate from `clean` so a video actually titled something
    /// like "Unknown Pleasures" doesn't get its title wiped.
    private static func cleanStat(_ s: Substring) -> String {
        let t = clean(s)
        return t.contains("Unknown") ? "" : t
    }

    private static func playlistPosition(index: String, total: String) -> String {
        guard !index.isEmpty else { return "" }
        return total.isEmpty ? index : "\(index)/\(total)"
    }
}

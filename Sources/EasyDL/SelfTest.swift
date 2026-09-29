import Foundation

/// `EasyDL --self-test` — the offline half of the test suite. It covers the decisions
/// the app makes on the user's behalf: what gets pulled out of a paste, which yt-dlp
/// arguments each choice produces, what a failure is explained as, and whether a saved
/// queue survives an upgrade. It needs no network and runs on every build.
///
/// The half that needs the network lives in `Tests/e2e.sh`, which drives real
/// downloads through this same argument builder.
enum SelfTest {

    private nonisolated(unsafe) static var checks = 0

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--self-test") else { return }

        testPastedText()
        testFormatChoices()
        testCookieChoices()
        testFallbackBehaviour()
        testInvariants()
        testPOTokenProvider()
        testSecurity()
        testProgressParsing()
        testDoneParsing()
        testDiagnosis()
        testQueuePersistence()
        testCleanupPolicy()
        testRevealWhenDone()

        print("EasyDL self-test: \(checks) checks passed")
        exit(0)
    }

    /// assert() alone vanishes in a release build, which is exactly the build we ship.
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition {
            FileHandle.standardError.write(Data("FAILED: \(message())\n".utf8))
            exit(1)
        }
    }

    // MARK: - What people paste into the Add sheet

    private static func testPastedText() {
        let one = YTDLP.extractURLs(from: "https://youtu.be/abc")
        check(one == ["https://youtu.be/abc"], "single URL, got \(one)")

        // The documented way: one per line, with the stray blank lines and indentation
        // that come from copying out of a notes app.
        let lines = YTDLP.extractURLs(from: """

              https://youtu.be/a

            https://youtu.be/b
        """)
        check(lines == ["https://youtu.be/a", "https://youtu.be/b"], "multi-line, got \(lines)")

        // Several on one line — what you get pasting from a chat message.
        let inline = YTDLP.extractURLs(from: "https://youtu.be/a https://youtu.be/b")
        check(inline.count == 2, "space separated, got \(inline)")

        // A link inside a sentence, and one a mail client wrapped in angle brackets.
        let prose = YTDLP.extractURLs(from: "watch this: <https://youtu.be/a>, then https://youtu.be/b.")
        check(prose == ["https://youtu.be/a", "https://youtu.be/b"], "prose, got \(prose)")

        // Quotes and trailing punctuation must not become part of the URL.
        let quoted = YTDLP.extractURLs(from: "\"https://youtu.be/a\" (https://youtu.be/b);")
        check(quoted == ["https://youtu.be/a", "https://youtu.be/b"], "quoted, got \(quoted)")

        // Query strings carry playlist ids and timestamps — they must survive intact.
        let q = YTDLP.extractURLs(from: "https://www.youtube.com/watch?v=a&list=PL123&t=42")
        check(q == ["https://www.youtube.com/watch?v=a&list=PL123&t=42"], "query lost: \(q)")

        // The same link twice in one paste is a slip, not a request for two downloads.
        let dupes = YTDLP.extractURLs(from: "https://youtu.be/a\nhttps://youtu.be/a")
        check(dupes.count == 1, "duplicates should collapse, got \(dupes)")

        // ...but two genuinely different links are kept, in the order given.
        let order = YTDLP.extractURLs(from: "https://youtu.be/b\nhttps://youtu.be/a")
        check(order == ["https://youtu.be/b", "https://youtu.be/a"], "order changed: \(order)")

        check(YTDLP.extractURLs(from: "http://example.com/v").count == 1, "plain http rejected")

        // Nothing usable must produce nothing, never a bogus item.
        for junk in ["", "   \n  ", "just some notes", "ftp://host/f", "youtube.com/watch?v=a",
                     "https://", "file:///etc/passwd"] {
            check(YTDLP.extractURLs(from: junk).isEmpty, "junk accepted: \(junk)")
        }
    }

    // MARK: - The format and quality pickers

    private static func testFormatChoices() {
        // Every ceiling the picker offers must reach yt-dlp as a hard filter. A sort
        // preference would hand back 1080p when 720p was asked for.
        for q in Quality.allCases where q.maxHeight != nil {
            let h = q.maxHeight!
            let a = args(kind: .videoMP4, quality: q)
            check(a.contains("bv*[height<=\(h)]+ba/b[height<=\(h)]/bv*+ba/b"),
                  "\(q.rawValue) not capped: \(a)")
            check(a.contains("--merge-output-format") && a.contains("mp4"), "\(q) not mp4")
        }

        let best = args(kind: .videoMP4, quality: .best)
        check(best.contains("bv*+ba/b"), "best selector wrong: \(best)")
        check(!best.contains(where: { $0.contains("height<=") }), "best must not cap")

        // MP3 downloads audio only, and the quality picker is disabled for it — so a
        // stale quality value must never leak into the request.
        for q in Quality.allCases {
            let a = args(kind: .audioMP3, quality: q)
            check(a.contains("-x") && a.contains("mp3"), "mp3 flags missing")
            check(a.contains("ba/b"), "mp3 should take audio only: \(a)")
            check(!a.contains(where: { $0.contains("height<=") }), "\(q) leaked into MP3")
            check(!a.contains("--merge-output-format"), "mp3 needs no merge")
        }

        check(Quality.best.label == "Best available", "label: \(Quality.best.label)")
        check(Quality.p720.label == "720p", "label: \(Quality.p720.label)")
    }

    // MARK: - Sign-in

    private static func testCookieChoices() {
        check(!args(kind: .videoMP4).contains(where: { $0.hasPrefix("--cookies") }),
              "cookies must be opt-in")

        var browser = spec()
        browser.cookiesBrowser = "safari"
        let b = YTDLP.arguments(for: browser)
        check(b.contains("--cookies-from-browser") && b.contains("safari"), "browser cookies: \(b)")

        var file = spec()
        file.cookieFile = "/tmp/c.txt"
        let f = YTDLP.arguments(for: file)
        check(f.contains("--cookies") && f.contains("/tmp/c.txt"), "cookie file: \(f)")
        check(!f.contains("--cookies-from-browser"), "file must not also read a browser")

        // Both set: the file wins, because reading a live browser profile needs a macOS
        // grant that resets on every rebuild.
        var both = spec()
        both.cookiesBrowser = "chrome"
        both.cookieFile = "/tmp/c.txt"
        let bo = YTDLP.arguments(for: both)
        check(bo.contains("/tmp/c.txt") && !bo.contains("--cookies-from-browser"),
              "file should win: \(bo)")

        check(CookieSource.none.ytdlpValue.isEmpty, "'none' must emit nothing")
        check(CookieSource.chrome.ytdlpValue == "chrome", "chrome value")
    }

    // MARK: - The 403 retry

    private static func testFallbackBehaviour() {
        check(!args(kind: .videoMP4).contains("--extractor-args"), "no fallback on first try")
        check(!args(kind: .audioMP3).contains("-S"), "no re-ranking on first try")

        var mp3 = spec(kind: .audioMP3)
        mp3.fallbackClient = "web_safari"
        let m = YTDLP.arguments(for: mp3)
        check(m.contains("--extractor-args") && m.contains("youtube:player_client=web_safari"),
              "fallback client missing: \(m)")
        // proto first prefers the single progressive file. The smaller HLS rungs drop
        // fragments on long videos — 2352 of 2608 lost, a 3h50m recording saved as 21
        // minutes, exit code 0.
        check(m.contains("-S") && m.contains("proto,abr,+size"), "fallback sort wrong: \(m)")
        check(m.contains("-x") && m.contains("mp3"), "fallback must still make an MP3")

        // The video fallback keeps the resolution the user asked for.
        var mp4 = spec(kind: .videoMP4, quality: .p720)
        mp4.fallbackClient = "web_safari"
        let v = YTDLP.arguments(for: mp4)
        check(v.contains("bv*[height<=720]+ba/b[height<=720]/bv*+ba/b"), "cap lost on fallback")

        // Forcing a YouTube player client is meaningless elsewhere, and re-ranking by
        // "smallest" on an unknown site could pick genuinely bad audio.
        for yes in ["https://www.youtube.com/watch?v=a", "https://youtu.be/a",
                    "https://m.youtube.com/watch?v=a", "https://www.youtube-nocookie.com/embed/a"] {
            check(Prefs.isYouTube(yes), "should be YouTube: \(yes)")
        }
        for no in ["https://vimeo.com/1", "https://notyoutube.com/a",
                   "https://youtube.com.evil.example/a", "not a url", ""] {
            check(!Prefs.isYouTube(no), "should not be YouTube: \(no)")
        }

        check(YTDLP.isForbidden(["ERROR: unable to download video data: HTTP Error 403: Forbidden"]),
              "403 not detected")
        check(!YTDLP.isForbidden(["[download] 100% of 5.00MiB"]), "success read as 403")
        check(!YTDLP.isForbidden([]), "empty read as 403")
    }

    // MARK: - The PO token provider

    private static func testPOTokenProvider() {
        // Optional: without one installed nothing extra is passed.
        check(!args(kind: .audioMP3).contains { $0.hasPrefix("youtubepot") },
              "provider args must not appear when none is installed")

        var s = spec(kind: .audioMP3)
        s.potServerHome = "/opt/prov/server"
        let a = YTDLP.arguments(for: s)
        check(a.contains("youtubepot-bgutilscript:server_home=/opt/prov/server"),
              "provider arg missing or malformed: \(a)")

        // The fallback and the provider address different extractors, so both are
        // passed as separate --extractor-args. yt-dlp merges repeated occurrences.
        s.fallbackClient = "web_safari"
        let both = YTDLP.arguments(for: s)
        check(both.filter { $0 == "--extractor-args" }.count == 2,
              "expected two --extractor-args, got \(both)")
        check(both.contains("youtube:player_client=web_safari"), "client arg lost")
        check(both.contains("youtubepot-bgutilscript:server_home=/opt/prov/server"),
              "provider arg lost")

        // A path only counts as a provider once it has actually been built, so a
        // half-finished checkout doesn't silently disable audio-only downloads.
        check(!Prefs.isPotHome(""), "empty path accepted")
        check(!Prefs.isPotHome("/definitely/not/here"), "missing path accepted")
        check(!Prefs.isPotHome(NSTemporaryDirectory()), "an unrelated directory accepted")
        check(Prefs.defaultPotHome.hasSuffix("EasyDL/pot-provider/server"),
              "default location moved: \(Prefs.defaultPotHome)")
    }

    // MARK: - Security

    private static func testSecurity() {
        // --- a hostile playlist name must not become a real ".." path component -----
        // yt-dlp replaces "/" inside a field value but leaves a lone ".." alone, and its
        // sanitize_path() does not drop ".." on macOS. The bracketed id suffix is keyed
        // on playlist_title, so the directory is never exactly "." or ".." even when the
        // id is missing. Tests/e2e.sh renders this against yt-dlp's real engine.
        let t = YTDLP.outputTemplate
        check(t.hasPrefix("%(playlist_title|.)s%(playlist_title& [|)s"),
              "the traversal guard was removed from the template: \(t)")
        check(t.contains("%(playlist_title&]|)s/"), "closing guard missing: \(t)")

        // --- double-click must not execute what the server chose to hand us ---------
        for safe in ["a.mp4", "a.MP4", "a.mkv", "a.mp3", "a.m4a", "a.webm", "a.srt",
                     "/Users/me/Downloads/Clip [id].mp4"] {
            check(YTDLP.isSafeToOpen(safe), "\(safe) should be openable")
        }
        for unsafe in ["a.command", "a.app", "a.sh", "a.scpt", "a.terminal", "a.workflow",
                       "a.pkg", "a.dmg", "a.jar", "a.py", "a.rb", "a.zip", "a.html",
                       "a.webloc", "a.url", "a.shortcut", "a", "", "a.", "noext",
                       "a.mp4.command", "/tmp/evil.command"] {
            check(!YTDLP.isSafeToOpen(unsafe), "\(unsafe) must NOT be opened")
        }

        // --- no argument injection through the one structured string we build -------
        // Everything else is its own argv entry; only extractor-args concatenates, where
        // ";" separates arguments and ":" ends the extractor name.
        for hostile in ["/tmp/p;youtube:player_client=evil", "/tmp/p:x", "/tmp/a;b"] {
            var s = spec()
            s.potServerHome = hostile
            let a = YTDLP.arguments(for: s)
            check(!a.contains { $0.contains(hostile) },
                  "a path containing ; or : reached extractor-args: \(hostile)")
        }
        var clean = spec()
        clean.potServerHome = "/opt/prov/server"
        check(YTDLP.arguments(for: clean).contains("youtubepot-bgutilscript:server_home=/opt/prov/server"),
              "an ordinary path should still be passed")

        // --- a URL can never be read as an option ----------------------------------
        for hostile in ["--exec=touch /tmp/pwned", "-o/tmp/x", "--paths=/etc", "-",
                        "--config-location=/tmp/evil.conf"] {
            check(YTDLP.extractURLs(from: hostile).isEmpty,
                  "option-shaped text was accepted as a URL: \(hostile)")
        }
        // ...and one that merely contains flag-looking text is passed as a single URL.
        let tricky = "https://example.com/a?x=--exec%20touch"
        check(YTDLP.extractURLs(from: tricky) == [tricky], "a legitimate URL was mangled")

        var u = spec()
        u.url = tricky
        let ua = YTDLP.arguments(for: u)
        check(ua.last == tricky, "URL must be last")
        check(ua[ua.count - 2] == "--", "URL must be preceded by -- so it can't parse as a flag")
    }

    // MARK: - Invariants that hold for every download

    private static func testInvariants() {
        for kind in Kind.allCases {
            for quality in Quality.allCases {
                for fallback in ["", "web_safari"] {
                    var s = spec(kind: kind, quality: quality)
                    s.fallbackClient = fallback
                    s.potServerHome = fallback.isEmpty ? "" : "/opt/prov/server"
                    let a = YTDLP.arguments(for: s)

                    check(a.last == s.url, "URL must be last, got \(a.last ?? "nil")")
                    check(a[a.count - 2] == "--", "the -- separator went missing")
                    check(a.filter { $0 == s.url }.count == 1, "URL appears twice")
                    // yt-dlp skips unavailable fragments and still exits 0, which writes
                    // a short file that looks perfectly valid.
                    check(a.contains("--abort-on-unavailable-fragments"), "truncation guard missing")
                    check(a.contains("--ignore-config"), "must not inherit ~/.config/yt-dlp")
                    check(a.contains("--progress"), "--print implies --quiet")
                    check(a.contains("--continue"), "should resume partial files")
                    check(a.contains("--paths") && a.contains(s.outputDir), "output dir missing")
                    check(a.contains("-o") && a.contains(YTDLP.outputTemplate), "template missing")
                    check(!a.contains(""), "empty argument would confuse yt-dlp")
                    check(a.contains("--progress-template"), "progress template missing")
                }
            }
        }

        // Paths the user picked can contain spaces and quotes; they travel as one
        // argv entry, so they must be passed through untouched rather than escaped.
        var odd = spec()
        odd.outputDir = "/Users/me/My Files/A \"B\" & C"
        check(YTDLP.arguments(for: odd).contains(odd.outputDir), "odd output dir mangled")

        // Playlists get a folder; single videos stay flat. The `|.` fallback resolves
        // to "./" which the path join swallows.
        check(YTDLP.outputTemplate.hasPrefix("%(playlist_title|.)s"), "playlist folder lost")
        check(YTDLP.outputTemplate.contains("]|)s/"), "the folder separator went missing")
        check(YTDLP.outputTemplate.contains("%(playlist_index&{:03d} - |)s"), "numbering lost")
        check(YTDLP.outputTemplate.contains("%(ext)s"), "extension lost")
    }

    // MARK: - Reading yt-dlp's progress back

    private static func testProgressParsing() {
        let line = "@@P@@  1.2%|   2.65MiB/s|00:07|NA|NA|sample-30s"
        guard let p = YTDLP.parseProgress(line) else {
            check(false, "a real progress line did not parse"); return
        }
        check(p.percent == 1.2, "percent \(String(describing: p.percent))")
        check(p.speed == "2.65MiB/s", "speed \(p.speed)")
        check(p.eta == "00:07", "eta \(p.eta)")
        check(p.playlistPosition.isEmpty, "NA should collapse, got \(p.playlistPosition)")
        check(p.title == "sample-30s", "title \(p.title)")

        let pl = YTDLP.parseProgress("@@P@@ 55.0%|  1.00MiB/s|00:03|3|20|Track Three")
        check(pl?.playlistPosition == "3/20", "playlist position \(pl?.playlistPosition ?? "nil")")

        // A title containing the separator must not shear the fields apart.
        let bar = YTDLP.parseProgress("@@P@@ 10.0%|  1.00MiB/s|00:03|1|2|Rock | Roll | Live")
        check(bar?.title == "Rock | Roll | Live", "title with pipes: \(bar?.title ?? "nil")")
        check(bar?.eta == "00:03", "fields sheared")

        // yt-dlp writes "Unknown B/s", not a bare "Unknown".
        let unknown = YTDLP.parseProgress("@@P@@  0.0%| Unknown B/s|Unknown|NA|NA|clip")
        check(unknown?.speed.isEmpty == true && unknown?.eta.isEmpty == true, "Unknown should clear")

        // ...but that must not reach the title.
        let titled = YTDLP.parseProgress("@@P@@ 50.0%|  1.00MiB/s|00:03|NA|NA|Unknown Pleasures")
        check(titled?.title == "Unknown Pleasures", "title wiped: \(titled?.title ?? "nil")")

        check(YTDLP.parseProgress("100.0%|1MiB/s") == nil, "unmarked line accepted")
        check(YTDLP.parseProgress("[youtube] Extracting URL: https://x") == nil, "chatter accepted")
        check(YTDLP.parseProgress("") == nil, "empty accepted")
    }

    private static func testDoneParsing() {
        let path = YTDLP.parseDone("@@DONE@@/Users/me/Downloads/Clip [abc].mp4")
        check(path == "/Users/me/Downloads/Clip [abc].mp4", "done path \(path ?? "nil")")
        // Playlist files land in a subfolder with spaces in the name.
        let sub = YTDLP.parseDone("@@DONE@@/Users/me/Downloads/My Mix/003 - Song [x].mp3")
        check(sub?.hasSuffix("003 - Song [x].mp3") == true, "subfolder path \(sub ?? "nil")")
        check(YTDLP.parseDone("[download] 100% of 5MiB") == nil, "chatter read as done")
        check(YTDLP.parseDone("@@DONE@@") == nil, "empty path accepted")
    }

    // MARK: - Explaining failures

    /// Every string here was produced by real yt-dlp during development.
    private static func testDiagnosis() {
        let safari = YTDLP.diagnose(["ERROR: [Errno 1] Operation not permitted: '/Users/x/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'"])
        check(safari?.offerFullDiskAccess == true, "Safari denial should offer the settings button")

        let blocked = YTDLP.diagnose([#"ERROR: could not find chrome cookies database in "/Users/x/Library/Application Support/Google/Chrome""#])
        check(blocked != nil && blocked?.offerFullDiskAccess == false, "blocked cookie folder")

        let cases: [(String, String)] = [
            ("ERROR: [youtube] a: Sign in to confirm you\u{2019}re not a bot.", "bot check"),
            ("ERROR: Could not copy Chrome cookie database. Please quit Chrome.", "locked database"),
            ("ERROR: unable to download video data: HTTP Error 403: Forbidden", "403"),
            ("ERROR: fragment 5 not found, unable to continue; giving up after 10 retries", "fragments"),
            ("ERROR: [youtube] a: Video unavailable", "unavailable"),
            ("ERROR: [youtube] a: Join this channel to get access to members-only content", "members only"),
            ("ERROR: ffmpeg not found. Please install", "missing ffmpeg"),
        ]
        for (line, what) in cases {
            check(YTDLP.diagnose([line]) != nil, "no explanation for \(what)")
        }

        // Ordinary output must never be reported as a problem.
        check(YTDLP.diagnose([]) == nil, "empty log diagnosed")
        check(YTDLP.diagnose(["[download] 100% of 5.00MiB"]) == nil, "success diagnosed")
        check(YTDLP.diagnose(["[ExtractAudio] Destination: a.mp3"]) == nil, "extraction diagnosed")
    }

    // MARK: - The saved queue

    private static func testQueuePersistence() {
        // A queue written before `triedFallback` existed. Swift's synthesized decoder
        // throws on a missing key, and load() swallows that — so without the lenient
        // decoder every saved download disappears silently on upgrade.
        let legacy = """
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","url":"https://x/v","kind":"audioMP3",
          "quality":"p1080","title":"Old","status":"failed","percent":0,"speed":"","eta":"",
          "playlistPosition":"","log":["boom"]}]
        """
        let restored = try? JSONDecoder().decode([DownloadItem].self, from: Data(legacy.utf8))
        check(restored?.count == 1, "a queue from an older build must still load")
        check(restored?.first?.triedFallback == false, "new field should default")
        check(restored?.first?.kind == .audioMP3, "kind lost")
        check(restored?.first?.log == ["boom"], "log lost")

        // A future build's extra key must not break today's decoder either.
        let future = #"[{"url":"https://x/v","somethingNew":true}]"#
        check((try? JSONDecoder().decode([DownloadItem].self, from: Data(future.utf8)))?.count == 1,
              "unknown keys should be ignored")

        // Round trip of everything the UI shows.
        var item = DownloadItem(url: "https://y", kind: .videoMP4, quality: .p720)
        item.title = "Rock | Roll"
        item.filePath = "/Users/me/Downloads/a b.mp4"
        item.status = .done
        item.percent = 100
        item.triedFallback = true
        let round = try? JSONDecoder().decode(DownloadItem.self,
                                              from: try! JSONEncoder().encode(item))
        check(round?.title == "Rock | Roll", "title round trip")
        check(round?.filePath == "/Users/me/Downloads/a b.mp4", "path round trip")
        check(round?.status == .done && round?.triedFallback == true, "state round trip")

        // A row with no URL is not a download; it must be rejected, not invented.
        check((try? JSONDecoder().decode([DownloadItem].self, from: Data("[{}]".utf8))) == nil,
              "url-less row accepted")
        check((try? JSONDecoder().decode([DownloadItem].self, from: Data("not json".utf8))) == nil,
              "garbage accepted")

        check(Status.done.isFinished && Status.failed.isFinished && Status.canceled.isFinished,
              "finished states")
        check(!Status.queued.isFinished && !Status.running.isFinished && !Status.paused.isFinished,
              "in-flight states")
    }

    // MARK: - Clearing out finished rows

    private static func testCleanupPolicy() {
        let now = Date()
        func row(_ status: Status, ago: TimeInterval?) -> DownloadItem {
            var i = DownloadItem(url: "https://x/\(status.rawValue)\(ago ?? -1)",
                                 kind: .videoMP4, quality: .best)
            i.status = status
            i.finishedAt = ago.map { now.addingTimeInterval(-$0) }
            return i
        }

        let hour = 3600.0
        let items = [
            row(.done, ago: hour),              // finished an hour ago
            row(.done, ago: 10 * 86_400),       // finished ten days ago
            row(.failed, ago: 2 * 86_400),      // failed two days ago
            row(.canceled, ago: 40 * 86_400),   // cancelled over a month ago
            row(.running, ago: nil),            // still going
            row(.queued, ago: nil),             // waiting
            row(.paused, ago: nil),             // paused by the user
        ]

        // The shipped default: a finished row does not survive the next launch.
        check(Prefs.defaultCleanupPolicy == .onLaunch,
              "default should clear on launch, got \(Prefs.defaultCleanupPolicy)")
        // ...and the opt-out still opts out.
        check(YTDLP.pruning(items, policy: .never, now: now).count == items.count,
              "\"keep them\" must change nothing")

        // An unfinished download is something to resume, never something to tidy away.
        for policy in CleanupPolicy.allCases {
            let kept = YTDLP.pruning(items, policy: policy, now: now)
            check(kept.contains { $0.status == .running }, "\(policy) removed a running row")
            check(kept.contains { $0.status == .queued }, "\(policy) removed a queued row")
            check(kept.contains { $0.status == .paused }, "\(policy) removed a paused row")
        }

        let launch = YTDLP.pruning(items, policy: .onLaunch, now: now)
        check(launch.count == 3, "on launch should leave only the 3 unfinished, got \(launch.count)")
        check(!launch.contains { $0.status.isFinished }, "a finished row survived")

        // Age policies keep what is still young. Failed and cancelled rows count as
        // finished too — they are clutter in exactly the same way.
        let day = YTDLP.pruning(items, policy: .afterDay, now: now)
        check(day.count == 4, "after a day should keep 3 unfinished + the 1h-old one, got \(day.count)")
        check(day.contains { $0.status == .done && $0.finishedAt != nil }, "the recent one was dropped")

        let week = YTDLP.pruning(items, policy: .afterWeek, now: now)
        check(week.count == 5, "after a week: + the 2-day-old failure, got \(week.count)")

        let month = YTDLP.pruning(items, policy: .afterMonth, now: now)
        check(month.count == 6, "after a month: all but the 40-day-old one, got \(month.count)")
        check(!month.contains { $0.status == .canceled }, "the 40-day-old row should be gone")

        // A finished row with no timestamp predates the field; it must not vanish
        // silently the first time an age policy is switched on.
        let undated = [row(.done, ago: nil)]
        check(YTDLP.pruning(undated, policy: .afterDay, now: now).count == 1,
              "an undated finished row was dropped by an age policy")
        check(YTDLP.pruning(undated, policy: .onLaunch, now: now).isEmpty,
              "on launch should still clear an undated row")

        check(CleanupPolicy.never.maxAge == nil, "never must mean never")
        check(CleanupPolicy.onLaunch.maxAge == 0, "on launch must mean immediately")
    }

    // MARK: - Opening the folder when the batch is over

    private static func testRevealWhenDone() {
        func rows(_ statuses: [Status]) -> [DownloadItem] {
            statuses.enumerated().map { i, st in
                var item = DownloadItem(url: "https://x/\(i)", kind: .videoMP4, quality: .best)
                item.status = st
                return item
            }
        }

        check(YTDLP.isIdle([]), "an empty queue is idle")
        check(YTDLP.isIdle(rows([.done])), "one finished download is idle")
        check(YTDLP.isIdle(rows([.done, .failed, .canceled])), "all-finished is idle")

        // Anything still to do means the batch is not over, so the Finder must not
        // open in the middle of a queue.
        check(!YTDLP.isIdle(rows([.done, .running])), "running counts as busy")
        check(!YTDLP.isIdle(rows([.done, .queued])), "queued counts as busy")

        // Paused is deliberate: the user stopped it, the batch is not finished, and
        // popping the Finder open then would be wrong.
        check(!YTDLP.isIdle(rows([.done, .paused])), "paused counts as busy")
        check(!YTDLP.isIdle(rows([.paused])), "a lone paused row is not idle")

        // A queue that only failed is idle, but there is nothing to show — the queue
        // guards on having collected at least one completed file.
        check(YTDLP.isIdle(rows([.failed, .canceled])), "failures leave the queue idle")
    }

    // MARK: - Helpers

    private static func spec(kind: Kind = .videoMP4, quality: Quality = .p1080) -> DownloadSpec {
        DownloadSpec(url: "https://example.com/v", kind: kind, quality: quality,
                     outputDir: "/tmp/out")
    }

    private static func args(kind: Kind = .videoMP4, quality: Quality = .p1080) -> [String] {
        YTDLP.arguments(for: spec(kind: kind, quality: quality))
    }
}

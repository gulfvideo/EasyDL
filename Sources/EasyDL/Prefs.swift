import Foundation
import Observation

/// Browsers yt-dlp can lift cookies from, so signed-in, members-only and
/// age-restricted videos work. YouTube increasingly refuses anonymous requests
/// outright, so this is closer to required than optional.
enum CookieSource: String, CaseIterable, Identifiable, Sendable {
    case none, safari, chrome, firefox, brave, edge, chromium, vivaldi, opera
    var id: String { rawValue }
    var ytdlpValue: String { self == .none ? "" : rawValue }
    var label: String { self == .none ? "Don't use cookies" : rawValue.capitalized }
}

@Observable
@MainActor
final class Prefs {
    static let shared = Prefs()

    private let defaults = UserDefaults.standard

    var outputDir: String        { didSet { defaults.set(outputDir, forKey: "outputDir") } }
    var defaultKind: Kind        { didSet { defaults.set(defaultKind.rawValue, forKey: "defaultKind") } }
    var defaultQuality: Quality  { didSet { defaults.set(defaultQuality.rawValue, forKey: "defaultQuality") } }
    var maxConcurrent: Int       { didSet { defaults.set(maxConcurrent, forKey: "maxConcurrent") } }
    var revealWhenDone: Bool     { didSet { defaults.set(revealWhenDone, forKey: "revealWhenDone") } }
    var cleanupPolicy: CleanupPolicy { didSet { defaults.set(cleanupPolicy.rawValue, forKey: "cleanupPolicy") } }
    var cookieSource: CookieSource { didSet { defaults.set(cookieSource.rawValue, forKey: "cookieSource") } }
    var cookieFile: String       { didSet { defaults.set(cookieFile, forKey: "cookieFile") } }
    var potOverride: String      { didSet { defaults.set(potOverride, forKey: "potOverride") } }
    var ytdlpOverride: String    { didSet { defaults.set(ytdlpOverride, forKey: "ytdlpOverride") } }
    var ffmpegOverride: String   { didSet { defaults.set(ffmpegOverride, forKey: "ffmpegOverride") } }

    private init() {
        let d = UserDefaults.standard
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Downloads"

        outputDir      = d.string(forKey: "outputDir") ?? downloads
        defaultKind    = Kind(rawValue: d.string(forKey: "defaultKind") ?? "") ?? .videoMP4
        defaultQuality = Quality(rawValue: d.string(forKey: "defaultQuality") ?? "") ?? .p1080
        maxConcurrent  = max(1, d.object(forKey: "maxConcurrent") as? Int ?? 2)
        revealWhenDone = d.bool(forKey: "revealWhenDone")   // off unless asked for
        cleanupPolicy  = CleanupPolicy(rawValue: d.string(forKey: "cleanupPolicy") ?? "")
            ?? Self.defaultCleanupPolicy
        cookieSource   = CookieSource(rawValue: d.string(forKey: "cookieSource") ?? "") ?? .none
        cookieFile     = d.string(forKey: "cookieFile") ?? ""
        potOverride    = d.string(forKey: "potOverride") ?? ""
        ytdlpOverride  = d.string(forKey: "ytdlpOverride") ?? ""
        ffmpegOverride = d.string(forKey: "ffmpegOverride") ?? ""
    }

    /// Finished rows are cleared each time the app opens. Only the list is cleared;
    /// the downloaded files are untouched, and nothing unfinished is ever removed.
    nonisolated static let defaultCleanupPolicy: CleanupPolicy = .onLaunch

    /// Where `install-pot-provider.sh` puts the provider.
    nonisolated static var defaultPotHome: String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("EasyDL/pot-provider/server").path
    }

    /// A provider directory only counts if it has actually been built.
    nonisolated static func isPotHome(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: path + "/package.json")
            && (fm.fileExists(atPath: path + "/src/generate_once.ts")
                || fm.fileExists(atPath: path + "/build/generate_once.js"))
    }

    var potServerHome: String? {
        let candidate = potOverride.isEmpty ? Self.defaultPotHome : potOverride
        return Self.isPotHome(candidate) ? candidate : nil
    }

    var ytdlpPath: String?  { Tools.locate("yt-dlp", override: ytdlpOverride) }
    var ffmpegPath: String? { Tools.locate("ffmpeg", override: ffmpegOverride) }

    /// yt-dlp wants the directory holding ffmpeg, not the binary itself.
    var ffmpegDir: String? { ffmpegPath.map { ($0 as NSString).deletingLastPathComponent } }

    nonisolated static func isYouTube(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        // Match on a label boundary, not a bare suffix: "notyoutube.com" ends with
        // "youtube.com" and would otherwise be treated as YouTube.
        return ["youtube.com", "youtu.be", "youtube-nocookie.com"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func spec(for item: DownloadItem) -> DownloadSpec {
        DownloadSpec(
            url: item.url,
            kind: item.kind,
            quality: item.quality,
            outputDir: outputDir,
            cookiesBrowser: cookieSource.ytdlpValue,
            cookieFile: cookieFile,
            ffmpegDir: ffmpegDir,
            // The fallback forces a YouTube player client, so it is meaningless
            // elsewhere — and "worst" on an unknown site could pick genuinely bad audio.
            // web_safari exposes both the HLS ladder and the progressive file, so one
            // client covers both cases; the -S sort decides which. ("tv" also serves
            // the progressive file but started failing extraction outright, which is
            // exactly why this isn't pinned to a single client per format.)
            fallbackClient: (item.triedFallback && Self.isYouTube(item.url)) ? "web_safari" : "",
            // With a provider installed the audio-only formats stop returning 403, so
            // the fallback above should rarely be reached at all.
            potServerHome: potServerHome ?? ""
        )
    }
}

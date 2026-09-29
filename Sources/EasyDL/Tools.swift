import Foundation

/// Locating yt-dlp and ffmpeg. A GUI app launched from the Finder gets a bare PATH
/// (/usr/bin:/bin:/usr/sbin:/sbin), so the Homebrew prefixes have to be named outright.
enum Tools {

    static let searchPaths = [
        "/opt/homebrew/bin",        // Apple silicon Homebrew
        "/usr/local/bin",           // Intel Homebrew, and most manual installs
        "/opt/local/bin",           // MacPorts
        "/usr/bin",
    ]

    static func locate(_ name: String, override: String = "") -> String? {
        if !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a tool and returns its trimmed stdout, or nil. Used only for `--version`,
    /// so blocking briefly is fine.
    static func capture(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

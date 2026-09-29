// Prints the exact yt-dlp arguments EasyDL would use, so the end-to-end tests drive
// the app's real argument builder instead of a hand-copied approximation of it.
// Compiled against Sources/EasyDL/Model.swift; see Tests/e2e.sh.
//
//   argsfor --url U --kind mp4|mp3 [--quality best|1080|720|...] --outdir D
//           [--cookies FILE] [--fallback CLIENT] [--ffmpeg DIR] [--pot SERVER_HOME]
//
// Arguments are written NUL-separated so paths containing spaces survive.
import Foundation

func value(_ flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

guard let url = value("--url"), let outdir = value("--outdir") else {
    FileHandle.standardError.write(Data("usage: argsfor --url U --kind mp4|mp3 --outdir D\n".utf8))
    exit(2)
}

let kind: Kind = (value("--kind") ?? "mp4") == "mp3" ? .audioMP3 : .videoMP4

let quality: Quality
switch value("--quality") ?? "best" {
case "2160": quality = .p2160
case "1440": quality = .p1440
case "1080": quality = .p1080
case "720":  quality = .p720
case "480":  quality = .p480
case "360":  quality = .p360
default:     quality = .best
}

var spec = DownloadSpec(url: url, kind: kind, quality: quality, outputDir: outdir)
spec.cookieFile = value("--cookies") ?? ""
spec.fallbackClient = value("--fallback") ?? ""
spec.ffmpegDir = value("--ffmpeg")
spec.potServerHome = value("--pot") ?? ""

var out = Data()
for arg in YTDLP.arguments(for: spec) {
    out.append(Data(arg.utf8))
    out.append(0)
}
FileHandle.standardOutput.write(out)

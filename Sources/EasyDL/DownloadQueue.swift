import Foundation
import Observation
import AppKit

@Observable
@MainActor
final class DownloadQueue {

    var items: [DownloadItem] = []

    @ObservationIgnored private var processes: [UUID: Process] = [:]
    /// IDs we killed on purpose, so termination reads as "canceled" and not "failed".
    @ObservationIgnored private var canceling: Set<UUID> = []
    /// Files finished since the queue was last idle, so a batch opens the Finder once
    /// at the end rather than once per download.
    @ObservationIgnored private var freshlyCompleted: [String] = []
    @ObservationIgnored private let prefs = Prefs.shared

    private static let maxLogLines = 40

    init() { load() }

    // MARK: - Adding

    /// Accepts a blob of pasted or dropped text and pulls every http(s) URL out of it,
    /// one per line, so pasting a wall of links Just Works.
    @discardableResult
    func add(text: String, kind: Kind, quality: Quality) -> Int {
        let urls = YTDLP.extractURLs(from: text)

        for url in urls {
            items.append(DownloadItem(url: url, kind: kind, quality: quality))
        }
        save()
        pump()
        return urls.count
    }

    // MARK: - Queue control

    var activeCount: Int { items.filter { $0.status == .running || $0.status == .paused }.count }

    /// Starts as many queued items as the concurrency limit allows.
    func pump() {
        guard prefs.ytdlpPath != nil else { return }
        while activeCount < prefs.maxConcurrent,
              let next = items.firstIndex(where: { $0.status == .queued }) {
            launch(at: next)
        }
    }

    func pause(_ ids: Set<UUID>) {
        for id in ids where status(of: id) == .running {
            if let p = processes[id], p.isRunning {
                // SIGSTOP freezes yt-dlp mid-transfer; the server may drop the connection
                // on a long pause, in which case --continue picks it up again.
                //
                // SECURITY: suspend()/resume()/terminate() go through Foundation, which
                // knows whether this child is still alive. Sending a raw signal to a
                // stored pid races with the process exiting — the kernel may already have
                // recycled that pid for something else, and we would signal a stranger.
                _ = p.suspend()
                update(id) { $0.status = .paused; $0.speed = ""; $0.eta = "" }
            }
        }
    }

    func resume(_ ids: Set<UUID>) {
        for id in ids {
            switch status(of: id) {
            case .paused:
                if let p = processes[id], p.isRunning {
                    _ = p.resume()
                    update(id) { $0.status = .running }
                }
            case .failed, .canceled:
                update(id) { $0.status = .queued; $0.percent = 0; $0.log = [] }
            default:
                break
            }
        }
        pump()
    }

    func cancel(_ ids: Set<UUID>) {
        for id in ids {
            guard let s = status(of: id), !s.isFinished else { continue }
            if let p = processes[id], p.isRunning {
                canceling.insert(id)
                _ = p.resume()          // a suspended process can't act on terminate()
                p.terminate()
            } else {
                update(id) { $0.status = .canceled }
            }
        }
        save()
    }

    func retry(_ ids: Set<UUID>) {
        for id in ids where status(of: id)?.isFinished == true {
            update(id) { $0.status = .queued; $0.percent = 0; $0.speed = ""; $0.eta = ""; $0.log = [] }
        }
        pump()
    }

    /// Removes rows from the list. Anything still running is stopped first — the
    /// partial file is left on disk so a re-add resumes rather than restarts.
    func remove(_ ids: Set<UUID>) {
        cancel(ids)
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func removeFinished() {
        items.removeAll { $0.status.isFinished }
        save()
    }

    // MARK: - Running one download

    private func launch(at index: Int) {
        guard let ytdlp = prefs.ytdlpPath else { return }
        let item = items[index]
        let id = item.id

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlp)
        proc.arguments = YTDLP.arguments(for: prefs.spec(for: item))
        proc.currentDirectoryURL = URL(fileURLWithPath: prefs.outputDir)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice

        // yt-dlp is a Python program, so PYTHONPATH / PYTHONHOME / PYTHONSTARTUP in the
        // inherited environment can make it import code of someone else's choosing.
        // Nothing here needs them. PATH is kept deliberately: the PO token provider
        // resolves node/deno through it.
        var env = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONWARNINGS"] {
            env.removeValue(forKey: key)
        }
        proc.environment = env

        do {
            try proc.run()
        } catch {
            update(id) { $0.status = .failed; $0.log = ["Could not run yt-dlp: \(error.localizedDescription)"] }
            return
        }

        processes[id] = proc
        items[index].status = .running

        // This Task inherits @MainActor, so nothing crosses an isolation boundary; the
        // actual read blocks happen inside AsyncBytes, off the main thread.
        let bytes = pipe.fileHandleForReading.bytes
        Task {
            do {
                for try await line in bytes.lines { self.ingest(line, for: id) }
            } catch {
                // Pipe closed mid-read; termination handling below still runs.
            }
            await self.finish(id: id)
        }
    }

    /// One line of yt-dlp output.
    private func ingest(_ line: String, for id: UUID) {
        if let p = YTDLP.parseProgress(line) {
            update(id) {
                if let pct = p.percent { $0.percent = pct }
                $0.speed = p.speed
                $0.eta = p.eta
                $0.playlistPosition = p.playlistPosition
                if !p.title.isEmpty { $0.title = p.title }
            }
        } else if let path = YTDLP.parseDone(line) {
            update(id) {
                $0.filePath = path
                if $0.title.isEmpty {
                    $0.title = (path as NSString).lastPathComponent
                }
            }
        } else {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            update(id) {
                $0.log.append(trimmed)
                if $0.log.count > Self.maxLogLines { $0.log.removeFirst() }
            }
        }
    }

    private func finish(id: UUID) async {
        guard let proc = processes[id] else { return }

        // The pipe hit EOF, so the process has closed its stdio and is exiting. Poll
        // rather than waitUntilExit() so a wedged child can never block the main thread.
        // ponytail: 5s ceiling; if a tool ever needs longer, move the wait off-actor.
        for _ in 0..<250 where proc.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let wasCanceled = canceling.remove(id) != nil
        let signaled = proc.terminationReason == .uncaughtSignal
        let code = proc.terminationStatus
        processes[id] = nil

        update(id) {
            defer { if $0.status.isFinished && $0.finishedAt == nil { $0.finishedAt = Date() } }
            if wasCanceled || signaled {
                $0.status = .canceled
            } else if code == 0 {
                $0.status = .done
                $0.percent = 100
            } else if YTDLP.isForbidden($0.log) && !$0.triedFallback {
                // Requeue once against a different player client rather than making the
                // user discover the workaround. `triedFallback` stops this looping.
                $0.triedFallback = true
                $0.status = .queued
                $0.percent = 0
                $0.log = []
            } else {
                $0.status = .failed
            }
            $0.speed = ""
            $0.eta = ""
        }
        if let done = item(id), done.status == .done, let path = done.filePath {
            freshlyCompleted.append(path)
        }

        save()
        pump()
        revealIfBatchFinished()
    }

    /// Opens the download folder with the new files selected, once, when the whole
    /// queue has come to rest. Nothing is shown if everything failed or was cancelled.
    private func revealIfBatchFinished() {
        guard prefs.revealWhenDone, YTDLP.isIdle(items), !freshlyCompleted.isEmpty else { return }
        let urls = freshlyCompleted
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        freshlyCompleted.removeAll()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Helpers

    private func status(of id: UUID) -> Status? {
        items.first(where: { $0.id == id })?.status
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    func item(_ id: UUID) -> DownloadItem? { items.first(where: { $0.id == id }) }

    /// Stops every child process. Called on quit so we don't orphan yt-dlp.
    func terminateAll() {
        for (_, p) in processes where p.isRunning {
            _ = p.resume()
            p.terminate()
        }
        save()
    }

    // MARK: - Persistence

    private static let storeURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EasyDL", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("queue.json")
    }()

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
        // The queue records every URL you have downloaded. Application Support is
        // user-only already; this keeps that true if the file is ever copied elsewhere.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.storeURL.path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              var restored = try? JSONDecoder().decode([DownloadItem].self, from: data)
        else { return }

        // Nothing survives a quit, so anything mid-flight goes back in the queue.
        // yt-dlp's --continue picks the partial file up where it stopped.
        for i in restored.indices where !restored[i].status.isFinished {
            restored[i].status = .queued
            restored[i].speed = ""
            restored[i].eta = ""
        }
        // Rows finished before the timestamp existed age from now, rather than being
        // swept away the moment an age-based policy is switched on.
        let now = Date()
        for i in restored.indices where restored[i].status.isFinished && restored[i].finishedAt == nil {
            restored[i].finishedAt = now
        }

        let kept = YTDLP.pruning(restored, policy: prefs.cleanupPolicy, now: now)
        items = kept
        if kept.count != restored.count { save() }
    }
}

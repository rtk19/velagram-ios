import Foundation

struct PlaybackTransferSnapshot: Sendable {
    var downloaded: Int64 = 0
    var total: Int64 = 0
    var bytesPerSecond: Double = 0
    var delivered: Int64 = 0
    var waitingReads = 0
    var downloading = false
    var prefixOffset: Int64 = 0
    var prefixBytes: Int64 = 0
    var summary: String {
        let bytes = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let speed = ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .file)
        return "\(speed)/s · \(bytes) / \(size) cached"
    }
}

/// Structured numeric diagnostics only: no Telegram IDs, messages, names or URLs.
final class PlaybackDiagnostics: @unchecked Sendable {
    let id = UUID().uuidString
    let url: URL
    private let lock = NSLock()
    private let writes = DispatchQueue(label: "Velagram.Playback.diagnostics")
    private var state = PlaybackTransferSnapshot()
    private var samples: [(TimeInterval, Int64)] = []
    private var waiting: [UUID: Int64] = [:]
    private var written = 0
    init(total: Int64 = 0, directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Velagram/PlaybackDiagnostics")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appending(path: "playback-" + id + ".jsonl")
        state.total = total
        if directory == nil {
            let old = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for file in old.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).dropLast(7) { try? FileManager.default.removeItem(at: file) }
        }
    }
    func sample(_ file: TelegramFile, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            state.downloaded = file.downloadedSize; state.total = max(state.total, file.size)
            state.downloading = file.downloading; state.prefixOffset = file.downloadOffset; state.prefixBytes = file.downloadedPrefixSize
            if let last = samples.last, file.downloadedSize < last.1 { samples = [] }
            samples.append((now, file.downloadedSize))
            samples.removeAll { now - $0.0 > 4 }
            if samples.count > 1, let first = samples.first, now > first.0 {
                state.bytesPerSecond = Double(max(0, file.downloadedSize - first.1)) / (now - first.0)
            } else { state.bytesPerSecond = 0 }
        }
    }
    func snapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PlaybackTransferSnapshot {
        lock.withLock {
            var result = state; result.waitingReads = waiting.count
            if let last = samples.last, now - last.0 > 3 { result.bytesPerSecond = 0 }
            return result
        }
    }
    func beginRead(_ offset: Int64, count: Int) -> UUID {
        let key = UUID(); lock.withLock { waiting[key] = offset }
        event("read_wait", ["offset": Double(offset), "count": Double(count)])
        return key
    }
    func endRead(_ key: UUID) { lock.withLock { waiting[key] = nil } }
    func delivered(_ count: Int) { lock.withLock { state.delivered += Int64(count) } }
    func flush() { writes.sync {} }
    func event(_ event: String, _ values: [String: Double] = [:]) {
        let url = self.url; let id = self.id
        writes.async { [self] in
            guard written < 2_000_000 else { return }
            let record: [String: Any] = ["session": id, "time": Date().timeIntervalSince1970, "event": event, "metrics": values]
            guard var bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            #if DEBUG
            print("VELAGRAM_PLAYBACK " + String(decoding: bytes, as: UTF8.self))
            #endif
            bytes.append(10)
            if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: bytes); written += bytes.count
            }
        }
    }
}

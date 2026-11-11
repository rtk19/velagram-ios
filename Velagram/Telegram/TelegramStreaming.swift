import Foundation
import Network

struct TelegramByteRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    var count: Int64 { end - start + 1 }
    static func parse(_ header: String?, size: Int64) throws -> TelegramByteRange {
        guard size > 0 else { throw TelegramError(code: 416, message: "This file has no readable content.") }
        guard let header else { return TelegramByteRange(start: 0, end: size - 1) }
        guard header.lowercased().hasPrefix("bytes="), !header.contains(",") else { throw invalid }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw invalid }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw invalid }
            return TelegramByteRange(start: max(0, size - suffix), end: size - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { throw invalid }
        let end: Int64
        if parts[1].isEmpty { end = size - 1 }
        else { guard let requested = Int64(parts[1]), requested >= start else { throw invalid }; end = min(requested, size - 1) }
        return TelegramByteRange(start: start, end: end)
    }
    private static var invalid: TelegramError { TelegramError(code: 416, message: "Requested file range is unavailable.") }
}

actor TelegramFileReader {
    static let prefetchBytes: Int64 = 16_777_216
    let transport: any TelegramTransport
    let fileID: Int
    let diagnostics: PlaybackDiagnostics?
    // TDLib's confirmed downloaded ranges remain readable while the server's
    // cache lease is held. Do not ask TDLib twice for every 256 KB HTTP write.
    private struct CachedSpan {
        let path: String
        let start: Int64
        let end: Int64 // exclusive
        let completed: Bool
    }
    private var cachedSpans: [CachedSpan] = []
    private var requestedEnd: Int64 = 0
    private var recoveredMissingCache = false
    let bufferTimeout: TimeInterval
    init(transport: any TelegramTransport, fileID: Int, bufferTimeout: TimeInterval = 90, diagnostics: PlaybackDiagnostics? = nil) { self.transport = transport; self.fileID = fileID; self.bufferTimeout = bufferTimeout; self.diagnostics = diagnostics }
    func read(offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        if let span = cachedSpans.last(where: { offset >= $0.start && offset < $0.end }),
           span.completed || span.end - offset >= Self.prefetchBytes / 4 {
            do {
                return try await Self.readCached(path: span.path, offset: offset, count: Int(min(Int64(count), span.end - offset)))
            } catch {
                // Cache metadata can outlive its backing file after relocation.
                // Re-enter the normal recovery path rather than serving holes.
                cachedSpans.removeAll { $0.path == span.path }
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        var waitingID: UUID?
        defer { if let waitingID { diagnostics?.endRead(waitingID) } }
        let deadline = Date().addingTimeInterval(bufferTimeout)
        var requested = false
        while Date() < deadline {
            try Task.checkCancellation()
            let json = try await transport.call("getFile", ["file_id": .integer(Int64(fileID))])
            guard let file = TelegramFile(json) else { throw TelegramError(code: -1, message: "Telegram file is unavailable.") }
            diagnostics?.sample(file)
            let available: Int64
            if file.completed {
                available = max(0, file.size - offset)
            } else {
                let prefix = try await transport.call("getFileDownloadedPrefixSize", ["file_id": .integer(Int64(fileID)), "offset": .integer(offset)])
                available = min(max(0, prefix["size"].int64 ?? 0), max(0, file.size - offset))
            }
            if available > 0, !file.localPath.isEmpty {
                if waitingID != nil { diagnostics?.event("read_ready", ["offset": Double(offset), "wait_seconds": ProcessInfo.processInfo.systemUptime - started]) }
                let readCount = Int(min(Int64(count), available))
                guard let path = Self.readablePath(file.localPath) else {
                    diagnostics?.event("cache_path_missing", ["cached_bytes": Double(file.downloadedSize), "completed": file.completed ? 1 : 0])
                    guard !recoveredMissingCache else { throw TelegramError(code: -1, message: "The cached Telegram file is unavailable. Please retry this source.") }
                    recoveredMissingCache = true
                    // Only discard stale local metadata when no backing file exists.
                    _ = try await transport.call("deleteFile", ["file_id": .integer(Int64(fileID))])
                    requested = false
                    continue
                }
                if !file.completed, available < Self.prefetchBytes / 4, offset + available < file.size,
                   !file.downloading || requestedEnd - offset < Self.prefetchBytes / 4 {
                    requestedEnd = offset + Self.prefetchBytes
                    diagnostics?.event("prefetch", ["offset": Double(offset), "available": Double(available), "limit": Double(Self.prefetchBytes)])
                    _ = try? await transport.call("downloadFile", ["file_id": .integer(Int64(fileID)), "priority": .integer(16), "offset": .integer(offset), "limit": .integer(Self.prefetchBytes), "synchronous": .bool(false)])
                }
                cachedSpans.removeAll { $0.path == path && $0.start >= offset && $0.end <= offset + available }
                cachedSpans.append(CachedSpan(path: path, start: offset, end: offset + available, completed: file.completed))
                if cachedSpans.count > 8 { cachedSpans.removeFirst(cachedSpans.count - 8) }
                return try await Self.readCached(path: path, offset: offset, count: readCount)
            }
            if waitingID == nil { waitingID = diagnostics?.beginRead(offset, count: count) }
            if !requested || !file.downloading {
                diagnostics?.event("download_request", ["offset": Double(offset), "limit": Double(max(Self.prefetchBytes, Int64(count))), "active": file.downloading ? 1 : 0, "prefix_offset": Double(file.downloadOffset), "prefix_bytes": Double(file.downloadedPrefixSize)])
                _ = try await transport.call("downloadFile", ["file_id": .integer(Int64(fileID)), "priority": .integer(32),
                    "offset": .integer(offset), "limit": .integer(max(Self.prefetchBytes, Int64(count))), "synchronous": .bool(false)])
                requestedEnd = offset + max(Self.prefetchBytes, Int64(count))
                requested = true
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        diagnostics?.event("read_timeout", ["offset": Double(offset)])
        throw TelegramError(code: 408, message: "Telegram is taking too long to buffer this file. Check the connection and retry.")
    }
    private nonisolated static func readCached(path: String, offset: Int64, count: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let bytes = try handle.read(upToCount: count) ?? Data()
            guard !bytes.isEmpty else { throw TelegramError(code: -1, message: "Telegram's downloaded file could not be read.") }
            return bytes
        }.value
    }
    nonisolated static func readablePath(_ path: String) -> String? {
        let manager = FileManager.default
        if manager.fileExists(atPath: path) { return path }
        // iOS can relocate an app container when updating/reinstalling a build.
        guard let marker = path.range(of: "/VelagramTelegram/") else { return nil }
        let suffix = String(path[marker.upperBound...])
        let root = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "VelagramTelegram").standardizedFileURL
        let candidate = root.appending(path: suffix).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"), manager.fileExists(atPath: candidate.path) else { return nil }
        return candidate.path
    }

}

/// A loopback-only, randomly addressed HTTP byte-range endpoint. No media bytes
/// or Telegram credentials are exposed on Wi-Fi or sent to a remote proxy.
final class TelegramStreamServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Velagram.Telegram.stream")
    private let lock = NSLock()
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let readBytes: @Sendable (Int64, Int) async throws -> Data
    private let host: String
    private var baseURL: URL?
    private var resources: [String: (Data, String)] = [:]
    private let diagnostics: PlaybackDiagnostics?
    private let size: Int64
    private let mime: String
    private let onFailure: @Sendable (String) -> Void
    private let token = UUID().uuidString + UUID().uuidString
    private var stopped = false
    private let cacheLease: CacheUsage.Lease

    init(transport: any TelegramTransport, media: TelegramMedia, networkSharing: Bool = false, localFile: URL? = nil, diagnostics: PlaybackDiagnostics? = nil, onFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        guard let id = media.fileID, media.size > 0 else { throw TelegramError(code: -1, message: "Telegram did not provide a downloadable file size.") }
        self.cacheLease = try CacheUsage.shared.reader()
        self.diagnostics = diagnostics
        let reader = TelegramFileReader(transport: transport, fileID: id, diagnostics: diagnostics)
        if let localFile {
            readBytes = { offset, count in
                let handle = try FileHandle(forReadingFrom: localFile); defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset)); return try handle.read(upToCount: count) ?? Data()
            }
        } else { readBytes = { try await reader.read(offset: $0, count: $1) } }
        size = media.size
        if networkSharing {
            guard let address = LocalNetworkAddress.wifiIPv4() else { throw TelegramError(code: -1, message: "Connect this device and your TV to the same Wi-Fi network.") }
            host = address
        } else { host = "127.0.0.1" }
        self.onFailure = onFailure
        mime = media.mimeType.isEmpty ? (media.isVideo ? "video/mp4" : "application/octet-stream") : media.mimeType
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(filename: String) async throws -> URL {
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { promise in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    if let port = self.listener.port { promise.resume(returning: port) }
                    else { promise.resume(throwing: TelegramError(code: -1, message: "Could not open the local media stream.")) }
                case .failed(let error): self.listener.stateUpdateHandler = nil; promise.resume(throwing: error)
                case .cancelled: self.listener.stateUpdateHandler = nil; promise.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        let ext = (filename as NSString).pathExtension
        let safeExtension = ext.allSatisfy(\.isLetter) && ext.count < 12 ? ext : "mp4"
        let url = URL(string: "http://\(host):\(port.rawValue)/\(token)/stream.\(safeExtension)")!
        lock.withLock { baseURL = url }
        return url
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let allowed = lock.withLock { if stopped { return false }; connections[id] = connection; return true }
        guard allowed else { connection.cancel(); return }
        connection.start(queue: queue)
        let task = Task { [weak self] in
            guard let self else { connection.cancel(); return }
            defer { connection.cancel(); self.lock.withLock { self.connections[id] = nil; self.tasks[id] = nil } }
            do { try await serve(connection, onDisconnect: { [weak self] in self?.lock.withLock { self?.tasks[id]?.cancel() } }) }
            catch let error as TelegramError { self.diagnostics?.event("stream_error", ["code": Double(error.code)]); self.onFailure(error.localizedDescription) }
            catch { self.diagnostics?.event(Task.isCancelled ? "range_cancelled" : "range_io_error", ["code": Double((error as NSError).code)]) }
        }
        lock.withLock { tasks[id] = task }
    }
    private func serve(_ connection: NWConnection, onDisconnect: @escaping @Sendable () -> Void) async throws {
        var header = Data()
        while header.range(of: Data("\r\n\r\n".utf8)) == nil {
            let chunk = try await receive(connection)
            guard !chunk.isEmpty, header.count + chunk.count <= 16_384 else { return }
            header.append(chunk)
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            // VLC may send TCP FIN after its GET while continuing to read.
            // Closing the request direction does not cancel the response.
            if complete { self?.diagnostics?.event("request_half_closed") }
            if error != nil { onDisconnect() }
        }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ").map(String.init)
        guard request.count >= 2, ["GET", "HEAD"].contains(request[0]), request[1].hasPrefix("/\(token)/") else {
            try await send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection); return
        }
        if let resource = lock.withLock({ resources[request[1]] }) {
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(resource.1)\r\nContent-Length: \(resource.0.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            try await send(Data(response.utf8), to: connection)
            if request[0] != "HEAD" { try await send(resource.0, to: connection) }
            return
        }
        guard request[1].hasPrefix("/\(token)/stream.") else {
            try await send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection); return
        }
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let range: TelegramByteRange
        do { range = try TelegramByteRange.parse(rangeHeader, size: size) }
        catch {
            try await send(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection); return
        }
        diagnostics?.event("http_range", ["start": Double(range.start), "end": Double(range.end), "head": request[0] == "HEAD" ? 1 : 0])
        let contentRange = rangeHeader == nil ? "" : "Content-Range: bytes \(range.start)-\(range.end)/\(size)\r\n"
        let response = "HTTP/1.1 \(rangeHeader == nil ? "200 OK" : "206 Partial Content")\r\nAccept-Ranges: bytes\r\nAccess-Control-Allow-Origin: *\r\nContent-Type: \(mime)\r\nContent-Length: \(range.count)\r\n\(contentRange)Connection: close\r\n\r\n"
        try await send(Data(response.utf8), to: connection)
        guard request[0] != "HEAD" else { return }
        var offset = range.start
        while offset <= range.end {
            try Task.checkCancellation()
            let bytes = try await readBytes(offset, Int(min(262_144, range.end - offset + 1)))
            try await send(bytes, to: connection); diagnostics?.delivered(bytes.count); offset += Int64(bytes.count)
        }
    }
    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { promise in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error { promise.resume(throwing: error) } else { promise.resume(returning: data ?? Data()) }
            }
        }
    }
    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (promise: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { promise.resume(throwing: error) } else { promise.resume() }
            })
        }
    }
    func addResource(name: String, data: Data, mimeType: String) -> URL? {
        lock.withLock {
            guard let baseURL, !name.contains("/"), !name.contains("..") else { return nil }
            let url = baseURL.deletingLastPathComponent().appendingPathComponent(name)
            resources[url.path] = (data, mimeType)
            return url
        }
    }
    func stop() {
        cacheLease.release()
        listener.cancel()
        let active = lock.withLock { stopped = true; let values = (Array(connections.values), Array(tasks.values)); connections = [:]; tasks = [:]; return values }
        active.0.forEach { $0.cancel() }; active.1.forEach { $0.cancel() }
    }
    deinit { listener.cancel() }
}

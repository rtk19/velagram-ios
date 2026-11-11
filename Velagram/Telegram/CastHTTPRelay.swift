import Foundation
import Network

/// A token-addressed LAN relay, started only after the user chooses casting.
/// Header-authenticated streams and every HLS child resource retain the same
/// request headers without exposing credentials in the receiver URL.
final class CastHTTPRelay: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Velagram.Cast.relay")
    private let lock = NSLock()
    private let host: String
    private let token = UUID().uuidString + UUID().uuidString
    private let headers: [String: String]
    private let session: URLSession
    private var origins: [String: URL] = [:]
    private var baseURL: URL?
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    init(headers: [String: String], loopbackOnly: Bool = false, session: URLSession = .shared) throws {
        guard let host = loopbackOnly ? "127.0.0.1" : LocalNetworkAddress.wifiIPv4() else { throw TelegramError(code: -1, message: "Connect this device and your TV to the same Wi-Fi network.") }
        self.host = host; self.headers = headers; self.session = session
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(origin: URL) async throws -> URL {
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { promise in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    if let port = self.listener.port { promise.resume(returning: port) } else { promise.resume(throwing: AppError.noStream) }
                case .failed(let error): self.listener.stateUpdateHandler = nil; promise.resume(throwing: error)
                case .cancelled: self.listener.stateUpdateHandler = nil; promise.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }; listener.start(queue: queue)
        }
        lock.withLock { baseURL = URL(string: "http://\(host):\(port.rawValue)/\(token)/") }
        guard let url = register(origin) else { throw AppError.noStream }; return url
    }
    private func register(_ origin: URL) -> URL? {
        guard ["http", "https"].contains(origin.scheme?.lowercased() ?? "") else { return nil }
        return lock.withLock {
            guard let baseURL else { return nil }
            let existing = origins.first { $0.value == origin }?.key
            let id = existing ?? UUID().uuidString
            origins[id] = origin
            let ext = origin.pathExtension
            return baseURL.appendingPathComponent(id).appendingPathComponent(ext.isEmpty ? "resource" : "resource.\(ext)")
        }
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID(); lock.withLock { connections[id] = connection }; connection.start(queue: queue)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { connection.cancel(); self.lock.withLock { self.connections[id] = nil; self.tasks[id] = nil } }
            try? await self.serve(connection, onDisconnect: { [weak self] in self?.lock.withLock { self?.tasks[id]?.cancel() } })
        }
        lock.withLock { tasks[id] = task }
    }
    private func serve(_ connection: NWConnection, onDisconnect: @escaping @Sendable () -> Void) async throws {
        var data = Data()
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let chunk: Data = try await withCheckedThrowingContinuation { promise in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { bytes, _, _, error in
                    if let error { promise.resume(throwing: error) } else { promise.resume(returning: bytes ?? Data()) }
                }
            }
            guard !chunk.isEmpty, data.count + chunk.count <= 16_384 else { return }; data += chunk
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
            // An inbound FIN only ends the request body; response delivery continues.
            if error != nil { onDisconnect() }
        }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ").map(String.init)
        let path = request.count > 1 ? request[1].split(separator: "/").map(String.init) : []
        guard request.count > 1, path.count == 3, path[0] == token,
              let origin = lock.withLock({ origins[path[1]] }), ["GET", "HEAD", "OPTIONS"].contains(request[0]) else {
            try await send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection); return
        }
        if request[0] == "OPTIONS" {
            try await send(Data("HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Range, Content-Type\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection); return
        }
        var upstream = URLRequest(url: origin); upstream.httpMethod = request[0]; upstream.timeoutInterval = 30
        headers.forEach { upstream.setValue($0.value, forHTTPHeaderField: $0.key) }
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) { upstream.setValue(String(range.dropFirst(6)).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: upstream)
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        let mime = response.mimeType ?? "application/octet-stream"
        let hls = mime.lowercased().contains("mpegurl") || origin.pathExtension.lowercased() == "m3u8"
        var header = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\nAccess-Control-Allow-Origin: *\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        if hls, request[0] == "GET", (200..<300).contains(http.statusCode) {
            var manifest = Data()
            for try await byte in bytes { guard manifest.count < 2_097_152 else { throw AppError.noStream }; manifest.append(byte) }
            let rewritten = rewrite(String(decoding: manifest, as: UTF8.self), origin: response.url ?? origin)
            let result = Data(rewritten.utf8)
            header += "Content-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(result.count)\r\n\r\n"
            try await send(Data(header.utf8), to: connection); try await send(result, to: connection); return
        }
        header += "Content-Type: \(mime)\r\n"
        if let range = http.value(forHTTPHeaderField: "Content-Range") { header += "Content-Range: \(range)\r\n" }
        if response.expectedContentLength >= 0, http.value(forHTTPHeaderField: "Content-Encoding") == nil { header += "Content-Length: \(response.expectedContentLength)\r\n" }
        header += "\r\n"; try await send(Data(header.utf8), to: connection)
        if request[0] == "HEAD" { return }
        var chunk = Data(); chunk.reserveCapacity(65_536)
        for try await byte in bytes {
            try Task.checkCancellation(); chunk.append(byte)
            if chunk.count >= 65_536 { try await send(chunk, to: connection); chunk.removeAll(keepingCapacity: true) }
        }
        if !chunk.isEmpty { try await send(chunk, to: connection) }
    }
    private func rewrite(_ manifest: String, origin: URL) -> String {
        func route(_ value: String) -> String {
            guard let url = URL(string: value, relativeTo: origin)?.absoluteURL, let mapped = register(url) else { return value }
            return mapped.absoluteString
        }
        return manifest.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            if !trimmed.hasPrefix("#") { return route(trimmed) }
            guard let regex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#) else { return line }
            var result = line
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let value = Range(match.range(at: 1), in: line), let full = Range(match.range, in: result) else { continue }
                result.replaceSubrange(full, with: "URI=\"\(route(String(line[value])))\"")
            }
            return result
        }.joined(separator: "\n")
    }
    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (promise: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in if let error { promise.resume(throwing: error) } else { promise.resume() } })
        }
    }
    func stop() {
        listener.cancel()
        let active = lock.withLock { let value = (Array(connections.values), Array(tasks.values)); connections = [:]; tasks = [:]; origins = [:]; return value }
        active.0.forEach { $0.cancel() }; active.1.forEach { $0.cancel() }
    }
    deinit { listener.cancel() }
}

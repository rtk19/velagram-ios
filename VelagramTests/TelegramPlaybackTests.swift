import Foundation
import Network
import UIKit
import Testing
import VLCKit
@testable import Velagram

private final class TelegramFixtureBundle: NSObject {}

struct TelegramPlaybackTests {
    @MainActor @Test func matroskaStreamsThroughTDLibRangeBridgeWithAudioAndSubtitles() async throws {
        let url = try #require(Bundle(for: TelegramFixtureBundle.self).url(forResource: "TelegramPlayback", withExtension: "mkv"))
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let file = TelegramJSON.request("file", ["id": .integer(1), "size": .integer(Int64(size)), "local": .object([
            "path": .string(url.path), "is_downloading_completed": .bool(true), "downloaded_size": .integer(Int64(size))])])
        let transport = TelegramFixtureTransport { query in
            query.type == "getFile" ? file : .request("fileDownloadedPrefixSize", ["size": .integer(Int64(size))])
        }
        let media = TelegramMedia(chatID: 1, messageID: 1, fileID: 1, name: "TelegramPlayback.mkv", caption: "", date: .now,
            size: Int64(size), duration: 4, mimeType: "video/x-matroska", thumbnailFileID: nil, kind: .video, remoteURL: nil)
        let server = try TelegramStreamServer(transport: transport, media: media)
        defer { server.stop() }
        let stream = try await server.start(filename: media.name)
        let session = TelegramPlayerSession(media: media, store: TelegramStore(transport: transport), queue: [])
        session.duration = 4
        let player = session.player
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        player.drawable = surface
        player.media = VLCMedia(url: stream)
        player.play()
        defer { player.stop(); player.drawable = nil }
        var advanced = false
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            if player.state == .error { break }
            if player.time.intValue >= 500 { advanced = true; break }
        }
        #expect(advanced, "The real VideoLAN player must advance while reading the Telegram byte-range endpoint.")
        #expect(!player.audioTracks.isEmpty)
        #expect(!player.textTracks.isEmpty)
        session.seek(2)
        var sought = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if player.time.intValue >= 1500 { sought = true; break }
        }
        #expect(sought, "Seeking must reach the requested portion of the Telegram media, not restart near zero.")
    }
}

// VLC/iOS may close the request's write half while still reading its response.
// An inbound FIN is not cancellation of the server's outbound media stream.
struct TelegramHalfClosedHTTPTests {
    @Test func clientCanFinishSendingRequestAndStillReceiveMediaBody() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let payload = Data("half-closed client still receives these media bytes".utf8)
        try payload.write(to: path); defer { try? FileManager.default.removeItem(at: path) }
        let size = Int64(payload.count)
        let file = TelegramJSON.request("file", ["id": .integer(1), "size": .integer(size), "local": .object(["path": .string(path.path), "is_downloading_completed": .bool(true), "downloaded_size": .integer(size)])])
        let transport = DelayedPlaybackTransport(file: file, size: size)
        let media = TelegramMedia(chatID: 1, messageID: 1, fileID: 1, name: "fixture.mkv", caption: "", date: .now, size: size, duration: 1, mimeType: "video/x-matroska", thumbnailFileID: nil, kind: .video, remoteURL: nil)
        let server = try TelegramStreamServer(transport: transport, media: media); defer { server.stop() }
        let url = try await server.start(filename: media.name)
        let response = try await halfClosedHTTPGet(url)
        let separator = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        #expect(response[separator.upperBound...] == payload)
    }
}

private func halfClosedHTTPGet(_ url: URL) async throws -> Data {
    let connection = NWConnection(host: NWEndpoint.Host(url.host!), port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
    defer { connection.cancel() }
    let timeout = Task { try await Task.sleep(for: .seconds(5)); connection.cancel() }
    defer { timeout.cancel() }
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: connection.stateUpdateHandler = nil; done.resume()
            case .failed(let error): connection.stateUpdateHandler = nil; done.resume(throwing: error)
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "half-closed-fixture"))
    }
    let request = Data("GET \(url.path) HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-\r\nConnection: close\r\n\r\n".utf8)
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        connection.send(content: request, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
            if let error { done.resume(throwing: error) } else { done.resume() }
        })
    }
    var response = Data()
    while true {
        let part: (Data, Bool) = try await withCheckedThrowingContinuation { done in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                if let error { done.resume(throwing: error) } else { done.resume(returning: (data ?? Data(), complete)) }
            }
        }
        response.append(part.0)
        if part.1 { return response }
    }
}

private actor DelayedPlaybackTransport: TelegramTransport {
    nonisolated let updates = AsyncStream<TelegramJSON> { $0.finish() }
    let file: TelegramJSON
    let size: Int64
    init(file: TelegramJSON, size: Int64) { self.file = file; self.size = size }
    func request(_ query: TelegramJSON, timeout: TimeInterval) async throws -> TelegramJSON {
        try await Task.sleep(for: .milliseconds(100))
        return query.type == "getFile" ? file : .request("fileDownloadedPrefixSize", ["size": .integer(size)])
    }
}

struct TelegramMissingCacheTests {
    @Test func staleDownloadedMetadataIsResetWhenBackingFileHasDisappeared() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let payload = Data("newly downloaded bytes".utf8)
        try payload.write(to: path); defer { try? FileManager.default.removeItem(at: path) }
        let transport = MissingPlaybackCacheTransport(path: path.path, size: Int64(payload.count))
        let reader = TelegramFileReader(transport: transport, fileID: 1, bufferTimeout: 3)
        let bytes = try await reader.read(offset: 0, count: payload.count)
        #expect(bytes == payload)
        #expect(await transport.reset)
    }
    @Test func relocatedCachePathResolvesInsideCurrentContainer() throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "VelagramTelegram")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "relocation-test-" + UUID().uuidString
        let target = root.appending(path: name)
        try Data([1,2,3]).write(to: target); defer { try? FileManager.default.removeItem(at: target) }
        #expect(TelegramFileReader.readablePath("/old-container/Library/Caches/VelagramTelegram/" + name) == target.path)
        #expect(TelegramFileReader.readablePath("/old/VelagramTelegram/../../not-a-cache-file") == nil)
    }
}
private actor MissingPlaybackCacheTransport: TelegramTransport {
    nonisolated let updates = AsyncStream<TelegramJSON> { $0.finish() }
    var reset = false
    let path: String
    let size: Int64
    init(path: String, size: Int64) { self.path = path; self.size = size }
    func request(_ query: TelegramJSON, timeout: TimeInterval) async throws -> TelegramJSON {
        if query.type == "deleteFile" { reset = true; return .request("ok") }
        if query.type == "getFileDownloadedPrefixSize" { return .request("fileDownloadedPrefixSize", ["size": .integer(size)]) }
        return .request("file", ["id": .integer(1), "size": .integer(size), "local": .object([
            "path": .string(reset ? path : "/missing-" + UUID().uuidString), "downloaded_size": .integer(size), "is_downloading_completed": .bool(true)])])
    }
}

struct TelegramReadAheadTests {
    @Test func sequentialCachedReadsDoNotWaitForTDLibPerHTTPChunk() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let payload = Data(repeating: 0x5A, count: 8_388_608)
        try payload.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let transport = ReadAheadTransport(path: url.path, size: Int64(payload.count), completed: true)
        let reader = TelegramFileReader(transport: transport, fileID: 1)
        for offset in stride(from: 0, to: payload.count, by: 262_144) {
            let bytes = try await reader.read(offset: Int64(offset), count: 262_144)
            #expect(bytes == payload[offset..<(offset + 262_144)])
        }
        #expect(await transport.fileQueries == 1, "32 cached chunks must not incur 32 TDLib round trips.")
        #expect(await transport.prefixQueries == 0, "A completed file needs no prefix queries.")
    }

    @Test func partialCacheDoesNotServeSparseHolesAndExtendsBeforeWindowStops() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let size = 24_117_248
        let payload = Data(repeating: 0x36, count: size)
        try payload.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let transport = ReadAheadTransport(path: url.path, size: Int64(size), completed: false)
        let reader = TelegramFileReader(transport: transport, fileID: 1, bufferTimeout: 3)
        // The file exists in full on disk, but TDLib initially confirms only
        // 1 MB. Reads beyond that prefix must request bytes, not trust file size.
        _ = try await reader.read(offset: 0, count: 262_144)
        #expect(await transport.downloadOffsets == [0])
        _ = try await reader.read(offset: 14_155_776, count: 262_144)
        #expect(await transport.downloadOffsets == [0, 14_155_776], "Refill must overlap the old 16 MB window while downloading is still active.")
        _ = try await reader.read(offset: 22_020_096, count: 262_144)
        #expect(await transport.downloadOffsets == [0, 14_155_776, 22_020_096], "An unconfirmed seek range must go through TDLib.")
    }
}

private actor ReadAheadTransport: TelegramTransport {
    nonisolated let updates = AsyncStream<TelegramJSON> { $0.finish() }
    let path: String
    let size: Int64
    let completed: Bool
    var fileQueries = 0
    var prefixQueries = 0
    var downloadOffsets: [Int64] = []
    private var confirmedEnd: Int64 = 1_048_576
    init(path: String, size: Int64, completed: Bool) { self.path = path; self.size = size; self.completed = completed }
    func request(_ query: TelegramJSON, timeout: TimeInterval) async throws -> TelegramJSON {
        switch query.type {
        case "getFile":
            fileQueries += 1
            return .request("file", ["id": .integer(1), "size": .integer(size), "local": .object([
                "path": .string(path), "is_downloading_completed": .bool(completed),
                "is_downloading_active": .bool(true), "downloaded_size": .integer(confirmedEnd)])])
        case "getFileDownloadedPrefixSize":
            prefixQueries += 1
            return .request("fileDownloadedPrefixSize", ["size": .integer(max(0, confirmedEnd - (query["offset"].int64 ?? 0)))])
        case "downloadFile":
            let offset = query["offset"].int64 ?? 0
            downloadOffsets.append(offset)
            // Report only part of each new window as downloaded. The reader
            // must never treat a download request as proof bytes have arrived.
            confirmedEnd = min(size, offset + 2_097_152)
            return .request("ok")
        default: return .request("ok")
        }
    }
}

struct MatroskaCaptionCacheTests {
    @Test(arguments: ["TelegramInteraction", "TelegramStyledCaptions"])
    func extractsEmbeddedTextWithoutVideoDecoderStyling(_ name: String) async throws {
        let url = try #require(Bundle(for: TelegramFixtureBundle.self).url(forResource: name, withExtension: "mkv"))
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let reader = MatroskaCaptionCache()
        let cues = try #require(try await reader.captions(path: url.path, offset: 0, prefix: size, position: 0, trackIndex: 0))
        #expect(!cues.isEmpty)
        #expect(cues.allSatisfy { $0.startTime >= 0 && $0.endTime > $0.startTime })
        #expect(cues.allSatisfy { !$0.text.contains("{\\") && !$0.text.contains("Default,") })
    }
}

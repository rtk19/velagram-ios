import Foundation
import Testing
@testable import Velagram

private final class CastFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    static func recorded() -> [URLRequest] { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = [] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cast-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let path = request.url!.path
        let body: Data
        var headers: [String: String] = [:]
        var status = 200
        if path == "/master.m3u8" {
            body = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000\nchild.m3u8\n".utf8)
            headers["Content-Type"] = "application/vnd.apple.mpegurl"
        } else if path == "/child.m3u8" {
            body = Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)
            headers["Content-Type"] = "application/vnd.apple.mpegurl"
        } else if path == "/key.bin" { body = Data("test-key".utf8); headers["Content-Type"] = "application/octet-stream" }
        else {
            let bytes = Data((0..<256).map(UInt8.init))
            if request.value(forHTTPHeaderField: "Range") == "bytes=2-5" {
                status = 206; body = bytes.subdata(in: 2..<6); headers["Content-Range"] = "bytes 2-5/256"
            } else { body = bytes }
            headers["Content-Type"] = "video/mp2t"
        }
        headers["Content-Length"] = String(body.count)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Suite(.serialized)
struct CastHTTPRelayTests {
    @Test func rewritesNestedHLSAndKeysPreservesHeadersAndServesExactRanges() async throws {
        CastFixtureProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CastFixtureProtocol.self]
        let upstream = URLSession(configuration: configuration)
        defer { upstream.invalidateAndCancel() }
        let relay = try CastHTTPRelay(headers: ["Referer": "https://fixture.invalid/", "Authorization": "test-token"], loopbackOnly: true, session: upstream)
        defer { relay.stop() }
        let url = try await relay.start(origin: URL(string: "https://cast-fixture.invalid/master.m3u8")!)
        let (master, _) = try await URLSession.shared.data(from: url)
        let child = try #require(String(decoding: master, as: UTF8.self).components(separatedBy: .newlines).first { $0.hasPrefix("http://127.0.0.1") }.flatMap(URL.init(string:)))
        let (playlist, _) = try await URLSession.shared.data(from: child)
        let text = String(decoding: playlist, as: UTF8.self)
        let keyPattern = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        let match = try #require(keyPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let key = try #require(Range(match.range(at: 1), in: text).flatMap { URL(string: String(text[$0])) })
        #expect(try await URLSession.shared.data(from: key).0 == Data("test-key".utf8))
        let segment = try #require(text.components(separatedBy: .newlines).first { $0.hasPrefix("http://127.0.0.1") }.flatMap(URL.init(string:)))
        var request = URLRequest(url: segment); request.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        #expect(bytes == Data([2, 3, 4, 5]))
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(CastFixtureProtocol.recorded().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "test-token" && $0.value(forHTTPHeaderField: "Referer") == "https://fixture.invalid/" })
        let count = CastFixtureProtocol.recorded().count
        let (_, denied) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(url.port!)/wrong/token/file.m3u8")!)
        #expect((denied as? HTTPURLResponse)?.statusCode == 404)
        #expect(CastFixtureProtocol.recorded().count == count)
    }
}

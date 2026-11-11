import Foundation
import Testing
@testable import Velagram

private struct CacheFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "VelagramCacheTests-" + UUID().uuidString)
    var caches: URL { root.appending(path: "Caches") }
    var support: URL { root.appending(path: "Support") }
    var temporary: URL { root.appending(path: "Temporary") }
    let usage = CacheUsage()
    let defaults = UserDefaults(suiteName: "VelagramCacheTests-" + UUID().uuidString)!
    func manager() -> CacheManager { CacheManager(caches: caches, support: support, temporary: temporary, defaults: defaults, usage: usage, subtitleCache: nil, httpCache: URLCache(memoryCapacity: 0, diskCapacity: 0)) }
    func write(_ relative: String, bytes: Int = 512) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
private func cacheStatistics() -> TelegramJSON {
    .request("storageStatistics", ["size": .integer(600), "by_chat": .array([
        .object(["by_file_type": .array([
            .object(["file_type": .request("fileTypeVideo"), "size": .integer(100)]),
            .object(["file_type": .request("fileTypeDocument"), "size": .integer(200)]),
            .object(["file_type": .request("fileTypePhoto"), "size": .integer(50)]),
            .object(["file_type": .request("fileTypeThumbnail"), "size": .integer(25)]),
            .object(["file_type": .request("fileTypeAudio"), "size": .integer(225)])
        ])])
    ])])
}
struct CacheManagementTests {
    @Test func storageBreakdownIncludesVideoDocumentsAndThumbnails() {
        let stats = TelegramCacheStatistics(cacheStatistics())
        #expect(stats.video == 300); #expect(stats.images == 75); #expect(stats.total == 600)
        #expect(stats.types.count == 5)
    }
    @Test func fullCleanupKeepsAccountLibraryAndOfflineDownloads() async throws {
        let fixture = CacheFixture(); defer { fixture.cleanup() }
        let protected = try ["Support/VelagramTelegramSession/db.sqlite", "Support/Velagram/TelegramDownloads/saved.mkv", "Support/Velagram/library.json", "Support/Imported/playlists.json", "Temporary/unrelated.data"].map { try fixture.write($0) }
        let disposable = try ["Caches/TMDBImages/image.tmdb-image", "Caches/Velagram/Subtitles/cues.json", "Support/Velagram/PlaybackDiagnostics/playback.jsonl", "Temporary/Velagram-HLS-example/master.m3u8"].map { try fixture.write($0) }
        let transport = TelegramFixtureTransport { _ in .request("storageStatistics", ["size": .integer(0)]) }
        try await fixture.manager().clear(.all, transport: transport)
        #expect(protected.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(disposable.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(fixture.defaults.double(forKey: "cache.lastCleaned") > 0)
    }
    @Test func videoCleanupUsesNativeEvictionAndDoesNotUnlinkTelegramFiles() async throws {
        let fixture = CacheFixture(); defer { fixture.cleanup() }
        let telegramFile = try fixture.write("Caches/VelagramTelegram/temp/managed-file")
        let transport = TelegramFixtureTransport { query in query.type == "getStorageStatistics" ? cacheStatistics() : .request("storageStatistics") }
        try await fixture.manager().clear(.videos, transport: transport)
        let queries = await transport.calls()
        let request = try #require(queries.first { $0.type == "optimizeStorage" })
        #expect(Set(request["file_types"].array.map(\.type)) == ["fileTypeVideo", "fileTypeDocument"])
        #expect(request["size"].int64 == 0); #expect(request["ttl"].int64 == 0)
        #expect(FileManager.default.fileExists(atPath: telegramFile.path)) // TDLib alone owns deletion.
    }
    @Test func activePlaybackBlocksCleanupBeforeAnyMutation() async throws {
        let fixture = CacheFixture(); defer { fixture.cleanup() }
        let image = try fixture.write("Caches/TMDBImages/test")
        let lease = try fixture.usage.reader(); defer { lease.release() }
        let transport = TelegramFixtureTransport()
        do { try await fixture.manager().clear(.all, transport: transport); Issue.record("Eviction should be blocked") }
        catch { #expect(error is CacheManagementError) }
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(await transport.calls().isEmpty)
    }
    @Test func retentionUsesLastAccessTTLSizeLimitAndSkipsActiveReaders() async throws {
        let fixture = CacheFixture(); defer { fixture.cleanup() }
        fixture.defaults.set(3, forKey: VideoCacheRetention.defaultsKey)
        fixture.defaults.set(2, forKey: CacheManager.sizeLimitKey)
        let transport = TelegramFixtureTransport()
        let manager = fixture.manager()
        let lease = try fixture.usage.reader()
        await manager.maintain(transport: transport, force: true)
        #expect(await transport.calls().isEmpty)
        lease.release()
        await manager.maintain(transport: transport, force: true)
        let request = try #require(await transport.calls().first)
        #expect(request["ttl"].int64 == Int64(259200))
        #expect(request["size"].int64 == Int64(2000000000))
        #expect(Set(request["file_types"].array.map(\.type)) == TelegramCacheStatistics.videoTypes)
    }
    @Test func foreverWithUnlimitedSizeDoesNotEvict() async {
        let fixture = CacheFixture(); defer { fixture.cleanup() }
        fixture.defaults.set(0, forKey: VideoCacheRetention.defaultsKey)
        let transport = TelegramFixtureTransport()
        await fixture.manager().maintain(transport: transport, force: true)
        #expect(await transport.calls().isEmpty)
    }
    @Test func cleanupLeasePreventsNewReadersAndReleasesIdempotently() throws {
        let usage = CacheUsage()
        let lease = try usage.eviction()
        #expect(throws: (any Error).self) { try usage.reader() }
        lease.release(); lease.release()
        let reader = try usage.reader(); reader.release()
        let next = try usage.eviction(); next.release()
    }
    @Test func overviewUsesAllocatedSpaceForSparseVideosAndKeepsDownloadsSeparate() async throws {
        let fixture = CacheFixture(); defer { fixture.cleanup() }
        let video = try fixture.write("Caches/VelagramTelegram/temp/sparse")
        let handle = try FileHandle(forWritingTo: video); try handle.truncate(atOffset: 100_000_000); try handle.close()
        _ = try fixture.write("Support/Velagram/TelegramDownloads/offline.mkv")
        let overview = await fixture.manager().overview(transport: nil)
        #expect(overview.video > 0 && overview.video < 1_000_000)
        #expect(overview.savedDownloads > 0)
        #expect(overview.total == overview.video)
    }
    @Test func policyChangeDuringPlaybackIsAppliedAtNextIdleCheck() async throws {
        let fixture = CacheFixture(); defer { fixture.cleanup() }
        let manager = fixture.manager(); let transport = TelegramFixtureTransport()
        let now = Date()
        await manager.maintain(transport: transport, now: now)
        let lease = try fixture.usage.reader()
        fixture.defaults.set(1, forKey: VideoCacheRetention.defaultsKey)
        await manager.maintain(transport: transport, force: true, now: now)
        lease.release()
        await manager.maintain(transport: transport, now: now.addingTimeInterval(1))
        let queries = await transport.calls()
        #expect(queries.count == 2)
        #expect(queries.last?["ttl"].int64 == Int64(86400))
    }

}

import Foundation
import Testing
@testable import Velagram

private struct CacheFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "VelagramCacheTests-" + UUID().uuidString)
    var caches: URL { root.appending(path: "Caches") }
    var support: URL { root.appending(path: "Support") }
    var temporary: URL { root.appending(path: "Temporary") }
    let usage = CacheUsage()
    private let defaultsSuiteName = "VelagramCacheTests-" + UUID().uuidString
    // Share the suite's settings without sharing a non-Sendable instance with the cache actor.
    var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuiteName)! }
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

struct OfflineLibraryTests {
    private func request(season: Int = 1, episode: Int = 1, provider: String = "tmdb") -> PlaybackRequest {
        PlaybackRequest(media: MediaItem(id: "show", providerID: provider, kind: .series, title: "Offline Show", tmdbID: 123),
                        episode: MediaEpisode(id: "\(provider)-\(season)-\(episode)", providerID: provider, showID: "show", seasonNumber: season, number: episode, title: "Episode \(episode)", overview: "Saved synopsis", posterURL: nil))
    }
    private func media(_ id: Int64 = 1) -> TelegramMedia {
        TelegramMedia(chatID: -1, messageID: id, fileID: Int(id), name: "Offline.Show.S01E01.mkv", caption: "", date: .now, size: 1024, duration: 1200, mimeType: "video/x-matroska", thumbnailFileID: nil, kind: .video, remoteURL: nil)
    }
    @Test func metadataSurvivesEncodingAndMatchesAcrossProvidersWithoutMixingEpisodes() throws {
        let original = request()
        let record = TelegramSavedDownload(media: media(), filename: "episode.mkv", savedAt: .now, catalogMedia: original.media, catalogEpisode: original.episode, artworkFilename: "poster.jpg", titleArtworkFilename: "landscape.jpg")
        let restored = try JSONDecoder().decode(TelegramSavedDownload.self, from: JSONEncoder().encode(record))
        #expect(restored.request == original)
        #expect(restored.matches(request(provider: "jellyfin")))
        #expect(!restored.matches(request(season: 2)))
        #expect(!restored.matches(request(episode: 2)))
        #expect(!restored.isCached)
        #expect(restored.artworkURL?.lastPathComponent == "poster.jpg")
        #expect(restored.titleArtworkURL?.lastPathComponent == "landscape.jpg")
        #expect(restored.artworkFilenames == ["poster.jpg", "landscape.jpg"])
    }
    @Test func legacyTelegramDownloadsRemainReadable() throws {
        let original = TelegramSavedDownload(media: media(), filename: "legacy.mkv", savedAt: .now)
        let restored = try JSONDecoder().decode(TelegramSavedDownload.self, from: JSONEncoder().encode(original))
        #expect(restored.catalogMedia == nil)
        #expect(!restored.isCached)
        #expect(restored.filename == "legacy.mkv")
    }
    @Test @MainActor func localSourcesPreferDownloadsAndIgnoreEvictedCache() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([1]).write(to: root); defer { try? FileManager.default.removeItem(at: root) }
        let downloads = TelegramDownloads()
        let value = request()
        downloads.saved = [TelegramSavedDownload(media: media(), filename: "", savedAt: .now, catalogMedia: value.media, catalogEpisode: value.episode, cachedPath: root.path)]
        #expect(downloads.available(for: value).count == 1)
        #expect(downloads.local(media()) == root)
        try FileManager.default.removeItem(at: root)
        #expect(downloads.available(for: value).isEmpty)
        #expect(downloads.local(media()) == nil)
    }
    @Test @MainActor func offlineNextEpisodeUsesOnlyAvailableUnwatchedEpisodes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "video.mkv"); try Data([1]).write(to: video)
        let downloads = TelegramDownloads()
        downloads.saved = [2, 3, 4].map { number in
            let next = request(episode: number)
            return TelegramSavedDownload(media: media(Int64(number)), filename: "", savedAt: .now, catalogMedia: next.media, catalogEpisode: next.episode, cachedPath: number == 2 ? root.appending(path: "evicted.mkv").path : video.path)
        }
        let library = LibraryStore(directory: root.appending(path: "library"))
        library.markFinished(request: request(episode: 3), nextRequest: nil)
        #expect(downloads.nextAvailable(after: request(), library: library)?.episode?.number == 4)
    }
    @Test func duplicateMessageLocationsCollapseAndPreferSavedRelease() {
        let value = request()
        let records = (1...6).map { number in
            TelegramSavedDownload(media: media(Int64(number)), filename: number == 1 ? "saved.mkv" : "", savedAt: .now, catalogMedia: value.media, catalogEpisode: value.episode, cachedPath: number == 1 ? nil : "/cache/\(number)")
        }
        let unique = OfflineLibraryIndex.unique(records)
        #expect(unique.count == 1)
        #expect(unique.first?.isCached == false)
        #expect(unique.first?.filename == "saved.mkv")
    }
    @Test func distinctEpisodesAreNeverCollapsedEvenWithGenericReleaseNames() {
        let records = [1, 2].map { number in
            let value = request(episode: number)
            return TelegramSavedDownload(media: media(Int64(number)), filename: "\(number).mkv", savedAt: .now, catalogMedia: value.media, catalogEpisode: value.episode)
        }
        #expect(OfflineLibraryIndex.unique(records).count == 2)
    }
    @Test func titleNavigatorContainsEpisodesOnceAndRetainsDistinctSources() {
        let sources = [1, 1, 2].enumerated().map { index, episode in
            OfflineLibrarySource(id: "release-\(index)", media: media(Int64(index + 1)), request: request(episode: episode), record: nil, transferID: "web:release-\(index)", provider: "Fixture")
        }
        let titles = OfflineLibraryIndex.titles(sources)
        #expect(titles.count == 1)
        #expect(titles.first?.contents.count == 2)
        #expect(titles.first?.contents.first?.sources.count == 2)
    }
    @Test func titleSummarySeparatesAvailableEpisodeFromNextDownload() {
        let current = request()
        let next = request(episode: 2)
        let record = TelegramSavedDownload(media: media(), filename: "saved.mkv", savedAt: .now, catalogMedia: current.media, catalogEpisode: current.episode)
        let sources = [
            OfflineLibrarySource(id: "saved", media: media(), request: current, record: record, transferID: nil, provider: "Telegram"),
            OfflineLibrarySource(id: "next", media: media(2), request: next, record: nil, transferID: "web:next", provider: "Web")
        ]
        let title = OfflineLibraryIndex.titles(sources)[0]
        #expect(title.availabilityLabel == "1 episode")
        #expect(title.availableContents.first?.request.episode?.number == 1)
        #expect(title.activeContents.first?.request.episode?.number == 2)
    }
    @Test func legacyTitleIdentityStaysStableAfterBeginningOfflinePlayback() {
        let original = OfflineLibrarySource(id: "legacy", media: media(), request: nil, record: nil, transferID: nil, provider: "Telegram")
        let title = OfflineLibraryIndex.titles([original])[0]
        let enriched = OfflineLibrarySource(id: "legacy", media: media(), request: title.contents[0].request, record: nil, transferID: nil, provider: "Telegram")
        let updated = OfflineLibraryIndex.titles([enriched])[0]
        #expect(updated.id == title.id)
        #expect(updated.contents[0].id == title.contents[0].id)
    }
    @Test @MainActor func transferMetricsMeasureDeltaRatherThanExistingCacheAndHandleUnknownLength() {
        let downloads = TelegramDownloads()
        downloads.updateProgress("test", received: 100_000_000, total: 200_000_000, now: 10)
        downloads.updateProgress("test", received: 102_000_000, total: 200_000_000, now: 11)
        #expect(downloads.transferProgress["test"]?.bytesPerSecond == 2_000_000)
        #expect(downloads.transferProgress["test"]?.percentage == "51%")
        #expect(downloads.transferProgress["test"]?.sizeLabel == "102 MB of 200 MB")
        #expect(downloads.transferProgress["test"]?.speedLabel(now: 15) == "0 B/s")
        downloads.updateProgress("unknown", received: 100, total: -1, now: 10)
        #expect(downloads.transferProgress["unknown"]?.fraction == nil)
        #expect(downloads.transferProgress["unknown"]?.percentage == "—")
    }
    @Test func storageSeparatesCachedArtworkFromSavedDownloads() async throws {
        let fixture = CacheFixture(); defer { fixture.cleanup() }
        _ = try fixture.write("Support/Velagram/TelegramDownloads/saved.mkv")
        _ = try fixture.write("Support/Velagram/TelegramDownloads/saved.jpg")
        _ = try fixture.write("Support/Velagram/TelegramDownloads/cached.jpg")
        let value = request()
        let records = [
            TelegramSavedDownload(media: media(), filename: "saved.mkv", savedAt: .now, catalogMedia: value.media, catalogEpisode: value.episode, artworkFilename: "saved.jpg"),
            TelegramSavedDownload(media: media(2), filename: "", savedAt: .now, cachedPath: "/evictable/video.mkv", artworkFilename: "cached.jpg")
        ]
        let manifest = fixture.support.appending(path: "Velagram/TelegramDownloads/downloads.json")
        try JSONEncoder().encode(records).write(to: manifest)
        let overview = await fixture.manager().overview(transport: nil)
        #expect(overview.savedDownloads > 0)
        #expect(overview.images > 0)
        #expect(overview.total == overview.images)
    }
}

struct DownloadCoordinationTests {
    @MainActor @Test func playbackDoesNotReplaceAnOfflineTransferWithARange() async throws {
        let downloads = TelegramDownloads()
        let transport = TelegramFixtureTransport()
        let media = TelegramMedia(chatID: 1, messageID: 123, fileID: 123, name: "test.mp4", caption: "", date: .now, size: 100, duration: 10, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: nil)
        downloads.active[123] = media
        try await downloads.requestPlaybackRange(transport: transport, fileID: 123, offset: 50, limit: 10, priority: 32)
        #expect(await transport.calls().isEmpty)
        downloads.active[123] = nil
        try await downloads.requestPlaybackRange(transport: transport, fileID: 123, offset: 50, limit: 10, priority: 32)
        let calls = await transport.calls()
        #expect(calls.count == 1)
        #expect(calls.first?["offset"].int64 == 50)
    }

    @MainActor @Test func closingLastPlaybackOwnerCancelsTDLibWithoutDeletingCache() async throws {
        let downloads = TelegramDownloads()
        let transport = TelegramFixtureTransport()
        let first = TelegramPlaybackDownloadOwner(), second = TelegramPlaybackDownloadOwner()
        try await downloads.requestPlaybackRange(transport: transport, fileID: 123, offset: 0, limit: 100, priority: 16, owner: first)
        try await downloads.requestPlaybackRange(transport: transport, fileID: 123, offset: 50, limit: 100, priority: 16, owner: second)
        await downloads.endPlayback(transport: transport, fileID: 123, owner: first)
        #expect(await transport.calls().filter { $0.type == "cancelDownloadFile" }.isEmpty)
        await downloads.endPlayback(transport: transport, fileID: 123, owner: second)
        let calls = await transport.calls()
        #expect(calls.last?.type == "cancelDownloadFile")
        #expect(calls.last?["only_if_pending"].bool == false)
        #expect(!calls.contains { $0.type == "deleteFile" })
        do {
            try await downloads.requestPlaybackRange(transport: transport, fileID: 123, offset: 0, limit: 100, priority: 16, owner: second)
            Issue.record("A closed stream must not restart its download")
        } catch is CancellationError {}
        #expect(await transport.calls().count == calls.count)
    }

    @MainActor @Test func closingPlaybackPreservesExplicitOfflineDownload() async throws {
        let downloads = TelegramDownloads()
        let transport = TelegramFixtureTransport()
        let owner = TelegramPlaybackDownloadOwner()
        try await downloads.requestPlaybackRange(transport: transport, fileID: 123, offset: 50, limit: 100, priority: 16, owner: owner)
        downloads.active[123] = TelegramMedia(chatID: 1, messageID: 123, fileID: 123, name: "test.mp4", caption: "", date: .now, size: 100, duration: 10, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: nil)
        await downloads.endPlayback(transport: transport, fileID: 123, owner: owner)
        try await downloads.startOfflineTransfer(transport: transport, fileID: 123)
        let calls = await transport.calls()
        #expect(!calls.contains { $0.type == "cancelDownloadFile" })
        #expect(calls.last?["limit"].int64 == 0)
        #expect(calls.last?["offset"].int64 == 0)
    }

    @MainActor @Test func partialCacheAlsoIgnoresStaleSnapshotsAndResetsAfterDeletion() throws {
        let downloads = TelegramDownloads()
        func file(_ bytes: Int64) throws -> TelegramFile {
            try #require(TelegramFile(.request("file", ["id": .integer(123), "size": .integer(100), "local": .object(["path": .string("cache/video"), "downloaded_size": .integer(bytes)])])))
        }
        downloads.completed(try file(40))
        downloads.completed(try file(21))
        #expect(downloads.partialFiles[123]?.downloadedSize == 40)
        downloads.completed(try file(0))
        #expect(downloads.partialFiles[123] == nil)
    }

    @MainActor @Test func stoppingStreamServerCancelsItsTDLibPrefetch() async throws {
        let id = 987654
        let file = TelegramJSON.request("file", ["id": .integer(Int64(id)), "size": .integer(100), "local": .object(["downloaded_size": .integer(0), "is_downloading_active": .bool(true)])])
        let transport = TelegramFixtureTransport { query in
            query.type == "getFile" ? file : .request("ok")
        }
        let media = TelegramMedia(chatID: 1, messageID: Int64(id), fileID: id, name: "test.mp4", caption: "", date: .now, size: 100, duration: 10, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: nil)
        let server = try TelegramStreamServer(transport: transport, media: media)
        let url = try await server.start(filename: media.name)
        let read = Task { try? await URLSession.shared.data(from: url) }
        defer { server.stop(); read.cancel() }
        for _ in 0..<100 {
            if await transport.calls().contains(where: { $0.type == "downloadFile" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.calls().contains { $0.type == "downloadFile" })
        server.stop()
        for _ in 0..<100 {
            if await transport.calls().contains(where: { $0.type == "cancelDownloadFile" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.calls().contains { $0.type == "cancelDownloadFile" })
        #expect(!(await transport.calls()).contains { $0.type == "deleteFile" })
    }

    @MainActor @Test func progressIgnoresStalePollResponses() {
        let downloads = TelegramDownloads()
        downloads.updateProgress("telegram:123", received: 21, total: 100, now: 1)
        downloads.updateProgress("telegram:123", received: 11, total: 100, now: 2)
        #expect(downloads.transferProgress["telegram:123"]?.received == 21)
        downloads.updateProgress("telegram:123", received: 22, total: 100, now: 3)
        #expect(downloads.transferProgress["telegram:123"]?.percentage == "22%")
    }
}

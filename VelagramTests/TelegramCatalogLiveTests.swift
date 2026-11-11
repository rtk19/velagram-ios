import Foundation
import Testing
@testable import Velagram

/// Explicit opt-in only: reads an already authenticated simulator account.
/// Records counts/assertions, never private filenames, captions, or chat names.
struct TelegramCatalogLiveTests {
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["VELAGRAM_LIVE_TELEGRAM"] == "1"))
    func catalogSearchFindsAnExistingAccountRelease() async throws {
        let store = TelegramStore.shared
        await store.start()
        for _ in 0..<80 where !store.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(store.ready, "The simulator must already be signed in to Telegram.")
        let response = try await store.transport.call("searchMessages", ["query": .string(""), "offset": .string(""),
            "limit": .integer(100), "filter": .request("searchMessagesFilterVideo"), "min_date": .integer(0), "max_date": .integer(0)])
        let items = response["messages"].array.compactMap(TelegramMedia.parse)
        let item = try #require(items.first {
            let count = TelegramCatalogMatching.normalized($0.title).split(separator: " ").count
            return $0.isVideo && count >= 2 && count <= 8 && $0.episode != nil
        })
        let episode = item.episode.map { MediaEpisode(id: "live-test", providerID: "tmdb", showID: "live-test", seasonNumber: $0.season, number: $0.episode, title: nil, overview: nil, posterURL: nil) }
        let request = PlaybackRequest(media: MediaItem(id: "live-test", providerID: "tmdb", kind: episode == nil ? .movie : .series, title: item.title), episode: episode)
        let batches = LiveCatalogBatches()
        let recorder = LiveSearchRecorder(base: store.transport, target: item.id)
        try await TelegramCatalogSearch(transport: recorder).search(context: PlaybackLookupContext(request: request), pages: 2) { await batches.set($0) }
        let found = await batches.contains(item.id)
        print("LIVE CATALOG DIAGNOSTICS", "selfMatch", TelegramCatalogMatching.score(item, context: PlaybackLookupContext(request: request)) != nil,
              "titleTokens", TelegramCatalogMatching.normalized(item.title).split(separator: " ").count,
              "requestCounts", await recorder.counts, "rawTargetFound", await recorder.targetFound)
        #expect(found, "Catalog lookup must rediscover a known account video by its title and episode.")
        // A separate opt-in keeps the known live file-transfer failure distinct
        // from catalog discovery. Run with VELAGRAM_LIVE_TELEGRAM_BYTES=1 to probe it.
        guard ProcessInfo.processInfo.environment["VELAGRAM_LIVE_TELEGRAM_BYTES"] == "1" else { return }
        let fileID = try #require(item.fileID)
        let reader = TelegramFileReader(transport: store.transport, fileID: fileID, bufferTimeout: 12)
        do {
            let bytes = try await reader.read(offset: 0, count: 4096)
            #expect(!bytes.isEmpty, "The selected real Telegram release must supply readable media bytes.")
        } catch {
            let file = try await store.transport.call("getFile", ["file_id": .integer(Int64(fileID))])
            let prefix = try await store.transport.call("getFileDownloadedPrefixSize", ["file_id": .integer(Int64(fileID)), "offset": .integer(0)])
            print("LIVE DOWNLOAD DIAGNOSTICS", "size", file["size"].int, "downloadable", file["local"]["can_be_downloaded"].bool,
                  "active", file["local"]["is_downloading_active"].bool, "downloaded", file["local"]["downloaded_size"].int,
                  "prefix", prefix["size"].int, "hasPath", !(file["local"]["path"].string ?? "").isEmpty,
                  "connectionReady", store.connected)
            throw error
        }
    }
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["VELAGRAM_LIVE_HIMYM"] == "1"))
    func scansRequestedHowIMetYourMotherEpisodeUsingTranslatedAliases() async throws {
        let store = TelegramStore.shared; await store.start()
        for _ in 0..<80 where !store.ready { try await Task.sleep(for: .milliseconds(100)) }
        try #require(store.ready)
        let item = MediaItem(id: "1100", providerID: "tmdb", kind: .series, title: "How I Met Your Mother", originalTitle: "How I Met Your Mother", tmdbID: 1100)
        let episode = MediaEpisode(id: "s6e14", providerID: "tmdb", showID: "1100", seasonNumber: 6, number: 14, title: nil, overview: nil, posterURL: nil)
        let context = await AppEnvironment().playbackContext(for: PlaybackRequest(media: item, episode: episode))
        #expect(context.alternativeTitles.contains { $0.contains("פגשתי") }, "TMDB must supply the Hebrew title using the configured Vela API token.")
        let batches = LiveCatalogBatches()
        try await withThrowingTaskGroup(of: Void.self) { timed in
            timed.addTask { try await TelegramCatalogSearch(transport: store.transport).search(context: context, pages: 4) { await batches.set($0) } }
            timed.addTask { try await Task.sleep(for: .seconds(180)); throw TelegramError(code: 408, message: "Live scanner deadline") }
            defer { timed.cancelAll() }; _ = try await timed.next()
        }
        let media = await batches.items
        let groups = TelegramReleaseGroup.group(media)
        print("LIVE HIMYM SCAN COUNTS", "messages", media.count, "uniqueReleases", groups.count, "aliases", TelegramCatalogMatching.aliases(context).count,
              "queries", TelegramCatalogMatching.queries(context).count)
        #expect(!groups.isEmpty, "The requested episode should have discoverable Telegram releases in this signed-in account.")
    }

}
private actor LiveCatalogBatches {
    var items: [TelegramMedia] = []
    func set(_ value: [TelegramMedia]) { items = value }
    func contains(_ id: String) -> Bool { items.contains { $0.id == id } }
}

private actor LiveSearchRecorder: TelegramTransport {
    nonisolated let updates = AsyncStream<TelegramJSON> { $0.finish() }
    let base: any TelegramTransport
    let target: String
    var counts: [Int] = []
    var targetFound = false
    init(base: any TelegramTransport, target: String) { self.base = base; self.target = target }
    func request(_ query: TelegramJSON, timeout: TimeInterval) async throws -> TelegramJSON {
        let result = try await base.request(query, timeout: timeout)
        counts.append(result["messages"].array.count)
        if result["messages"].array.compactMap(TelegramMedia.parse).contains(where: { $0.id == target }) { targetFound = true }
        return result
    }
}

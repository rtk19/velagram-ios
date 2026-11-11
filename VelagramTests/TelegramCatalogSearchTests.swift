import Foundation
import Testing
@testable import Velagram

private actor CatalogBatches {
    var items: [TelegramMedia] = []
    func set(_ value: [TelegramMedia]) { items = value }
}
private struct CatalogFixtureProvider: PlaybackProvider {
    let id: String
    let fails: Bool
    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        if fails { throw AppError.noStream }
        return [PlaybackDiscoveryTests.candidate(id)]
    }
}
struct TelegramCatalogSearchTests {
    func context(title: String = "Example Show", year: String = "2025-01-01", episode: Int? = 2) -> PlaybackLookupContext {
        let item = MediaItem(id: "123", providerID: "tmdb", kind: episode == nil ? .movie : .series, title: title, releaseDate: year)
        let ep = episode.map { MediaEpisode(id: "123:1:\($0)", providerID: "tmdb", showID: "123", seasonNumber: 1, number: $0, title: nil, overview: nil, posterURL: nil) }
        return PlaybackLookupContext(request: PlaybackRequest(media: item, episode: ep))
    }
    func media(_ name: String, caption: String = "", id: Int64 = 1) -> TelegramMedia {
        TelegramMedia(chatID: 7, messageID: id, fileID: Int(id), name: name, caption: caption, date: .now,
                      size: 2_000_000_000, duration: 3600, mimeType: "video/x-matroska", thumbnailFileID: nil, kind: .video, remoteURL: nil)
    }
    @Test func exactEpisodeAndAliasesRejectAdjacentEpisodesAndSeasons() {
        var request = context(); request.alternativeTitles = ["סדרה לדוגמה"]
        #expect(TelegramCatalogMatching.score(media("Example_Show_S01E02_1080p.mkv"), context: request) != nil)
        #expect(TelegramCatalogMatching.score(media("סדרה לדוגמה עונה 1 פרק 2.mkv"), context: request) != nil)
        #expect(TelegramCatalogMatching.score(media("Example.Show.1x02.mkv"), context: request) != nil)
        #expect(TelegramCatalogMatching.score(media("Example.Show.S01E03.mkv"), context: request) == nil)
        #expect(TelegramCatalogMatching.score(media("Example.Show.S02E02.mkv"), context: request) == nil)
        #expect(TelegramCatalogMatching.score(media("Another.Show.S01E02.mkv"), context: request) == nil)
    }
    @Test func moviesRejectRemakesAndPartialWordTitleMatches() {
        let request = context(title: "It", year: "2017-09-01", episode: nil)
        #expect(TelegramCatalogMatching.score(media("It.2017.1080p.mkv"), context: request) != nil)
        #expect(TelegramCatalogMatching.score(media("It.1990.1080p.mkv"), context: request) == nil)
        #expect(TelegramCatalogMatching.score(media("Titanic.2017.1080p.mkv"), context: request) == nil)
        #expect(TelegramCatalogMatching.score(media("It.S01E02.mkv"), context: request) == nil)
    }
    @Test func releaseMetadataIncludesQualityContainerSizeAndRelease() {
        let metadata = TelegramCatalogMatching.metadata(media("Example_Show_S01E02_1080p_WEB-DL.mkv"))
        #expect(metadata.quality == "1080P")
        #expect(metadata.container == "MKV")
        #expect(metadata.releaseType == "WEB-DL")
        #expect(metadata.sizeBytes == 2_000_000_000)
    }
    @Test func searchUsesCatalogQueryAndRemotePaginationThenDeduplicates() async throws {
        let match = try fixture(#"{"id":1,"chat_id":7,"date":100,"content":{"@type":"messageDocument","caption":{"text":""},"document":{"file_name":"Example.Show.S01E02.1080p.mkv","mime_type":"video/x-matroska","document":{"id":1,"size":100}}}}"#)
        let wrong = try fixture(#"{"id":2,"chat_id":7,"date":100,"content":{"@type":"messageVideo","video":{"file_name":"Example.Show.S01E03.mp4","video":{"id":2,"size":100}}}}"#)
        let transport = TelegramFixtureTransport { query in
            .request("foundMessages", ["messages": .array([match, wrong]), "next_offset": .string(query["offset"].string == "" ? "older" : "")])
        }
        let batches = CatalogBatches()
        try await TelegramCatalogSearch(transport: transport).search(context: context()) { await batches.set($0) }
        #expect(await batches.items.map(\.messageID) == [1])
        let calls = await transport.calls()
        #expect(calls.filter { $0.type == "searchMessages" }.allSatisfy { $0["chat_id"] == .null })
        #expect(calls.contains { $0.type == "searchChats" })
        #expect(calls.contains { $0["offset"].string == "older" })
        #expect(calls.contains { $0["query"].string == "example show S01E02" })
    }
    @MainActor @Test func unavailableProviderDoesNotHideOtherSources() async {
        let model = TitleSourcesModel()
        await model.scan(context: context(), providers: [CatalogFixtureProvider(id: "works", fails: false), CatalogFixtureProvider(id: "fails", fails: true)], store: TelegramStore(transport: TelegramFixtureTransport()), pages: 1)
        #expect(model.web.map(\.id) == ["works"])
        #expect(model.statuses["fails"] == "Unavailable")
        #expect(model.statuses["telegram"] == "Sign in to include Telegram")
        #expect(!model.searching)
    }
}

import Testing
import Foundation
@testable import Velagram

struct IPTVTests {
    @Test func playlistHandlesQuotesHeadersAndDeduplication() throws {
        let playlist = """
        #EXTM3U x-tvg-url="guide.xml"
        #EXTINF:-1 tvg-id="kan11" tvg-logo="https://example.com/logo,a.png" group-title="News, Israel",כאן 11
        #EXTVLCOPT:http-referrer=https://example.com/
        stream.m3u8|User-Agent=Velagram%20Player
        #EXTINF:-1,Duplicate
        stream.m3u8
        #EXTINF:-1 radio="true" group-title="Radio",Station
        https://example.com/radio.mp3
        #EXTINF:-1,Unsupported
        acestream://1234
        """
        let result = PlaylistParser.parse(playlist, relativeTo: URL(string: "https://example.com/list/channels.m3u")!)
        #expect(result.channels.count == 2)
        let channel = try #require(result.channels.first)
        #expect(channel.name == "כאן 11")
        #expect(channel.group == "News, Israel")
        #expect(channel.guideID == "kan11")
        #expect(channel.headers["Referer"] == "https://example.com/")
        #expect(channel.headers["User-Agent"] == "Velagram Player")
        #expect(channel.url.absoluteString == "https://example.com/list/stream.m3u8")
        #expect(result.guideURL?.absoluteString == "https://example.com/list/guide.xml")
        #expect(result.channels.last?.isRadio == true)
    }

    @Test func xmltvPreservesTimeZonesAndRejectsReversedPrograms() throws {
        let xml = """
        <tv><programme channel="11" start="20261109120000 +0200" stop="20261109130000 +0200"><title>News &amp; weather</title><desc>Today</desc></programme><programme channel="11" start="20261109140000 +0200" stop="20261109130000 +0200"><title>Invalid</title></programme></tv>
        """
        let result = try XMLTVParser.parse(Data(xml.utf8))
        #expect(result.count == 1)
        #expect(result[0].title == "News & weather")
        #expect(result[0].end.timeIntervalSince(result[0].start) == 3600)
        #expect(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: result[0].start).hour == 10)
    }

    @Test func xtreamCredentialsAreEncodedAsQueryValues() throws {
        let url = XtreamClient.playlist(server: URL(string: "https://example.com/portal")!, username: "a&b", password: "p?x&=")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/portal/get.php")
        #expect(components.queryItems?.first { $0.name == "username" }?.value == "a&b")
        #expect(components.queryItems?.first { $0.name == "password" }?.value == "p?x&=")
    }

    @MainActor @Test func profilesKeepChannelDataAndProgressSeparate() throws {
        let suite = "VelagramTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        let original = try #require(store.profiles.first)
        try store.importText("#EXTM3U\n#EXTINF:-1,One\nhttps://example.com/one.m3u8")
        store.saveProgress("episode1", position: 60, duration: 3600)
        store.saveProgress("episode2", position: 120, duration: 3600)
        store.addProfile("Other")
        store.switchProfile(try #require(store.profiles.last))
        #expect(store.channels.isEmpty)
        #expect(store.progress.isEmpty)
        store.switchProfile(original)
        #expect(store.channels.count == 1)
        #expect(store.progress["episode1"]?.position == 60)
        #expect(store.progress["episode2"]?.position == 120)
        #expect(VelagramStore(defaults: defaults).channels.count == 1)
    }

    @Test func invalidNetworkSchemesAreRejected() {
        #expect(throws: (any Error).self) { try VelagramHTTP.url("file:///private/test") }
        #expect(throws: (any Error).self) { try VelagramHTTP.url("not a url") }
    }
}

struct IPTVOnDemandTests {
    @Test func playlistSeparatesLiveMoviesAndHebrewSeriesOverHTTP() {
        let result = PlaylistParser.parse("""
        #EXTM3U
        #EXTINF:-1 group-title="News",Channel
        http://example.test/live/u/p/1.ts
        #EXTINF:-1 group-title="סרטים",Movie 2020
        http://example.test/movie/u/p/2.mp4
        #EXTINF:-1 group-title="סדרות",HIMYM S06E14
        http://example.test/series/u/p/3.mkv
        """)
        #expect(result.channels.map(\.contentKind) == [nil, "movie", "episode"])
        #expect(result.channels.allSatisfy { $0.url.scheme == "http" })
    }
    @Test func candidatesPreserveHeadersAndRejectWrongEpisodes() async throws {
        let show = MediaItem(id: "1100", providerID: "tmdb", kind: .series, title: "How I Met Your Mother", tmdbID: 1100)
        let episode = MediaEpisode(id: "6-14", providerID: "tmdb", showID: "1100", seasonNumber: 6, number: 14, title: nil, overview: nil, posterURL: nil)
        let context = PlaybackLookupContext(request: PlaybackRequest(media: show, episode: episode))
        var good = LiveChannel(id: "good", name: "HIMYM S06E14 720p", url: URL(string: "http://example.test/series/u/p/1.mkv")!, group: "Series", headers: ["Referer": "http://example.test/"])
        good.contentKind = "episode"
        var wrong = good; wrong.name = "HIMYM S05E14"; wrong.catalogTMDBID = 1100
        #expect(!IPTVPlaybackProvider.matches(wrong, context: context))
        let candidates = try await IPTVPlaybackProvider(entries: [good, good, wrong], accounts: [], series: [], credentials: [:]).candidates(for: context)
        #expect(candidates.count == 1)
        let source = try await #require(candidates.first).resolve()
        #expect(source.url == good.url)
        #expect(source.headers == good.headers)
    }
    @MainActor @Test func removalPersistsWithoutDeletingChannelOrFavorite() throws {
        let suite = "IPTVRecentTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        let channel = LiveChannel(id: "one", name: "One", url: URL(string: "http://example.test/1.m3u8")!, group: "Live")
        store.channels = [channel]; store.toggleFavorite(channel); store.record(channel)
        store.saveProgress(channel.id, position: 10, duration: 60)
        store.removeRecent(channel)
        let restored = VelagramStore(defaults: defaults)
        #expect(restored.recent.isEmpty)
        #expect(restored.progress[channel.id] == nil)
        #expect(restored.channels.count == 1)
        #expect(restored.favorites.contains(channel.id))
    }
}

private final class IPTVAPIProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "iptv-fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        let body: String
        switch action {
        case "get_vod_streams": body = #"[{"stream_id":42,"name":"Movie 2020","container_extension":"mkv","tmdb":"123"}]"#
        case "get_series": body = #"[{"series_id":"7","name":"How I Met Your Mother","tmdb":1100}]"#
        default: body = #"{"episodes":{"6":[{"id":"99","episode_num":"14","container_extension":"mkv"},{"id":"100","episode_num":15,"container_extension":"mp4"}],"5":[{"id":"98","episode_num":14,"container_extension":"mp4"}]}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension IPTVOnDemandTests {
    @Test func xtreamLoadsMovieCatalogAndExactSeriesEpisode() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IPTVAPIProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let account = IPTVAccount(id: UUID(), server: URL(string: "http://iptv-fixture.test:8080/portal")!, name: "Fixture")
        let client = IPTVOnDemandClient(account: account, credentials: .init(username: "a&b", password: "p?x"), http: VelagramHTTP(session: session))
        let movies = try await client.movies()
        #expect(movies.first?.contentKind == "movie")
        #expect(movies.first?.catalogTMDBID == 123)
        #expect(movies.first?.url.pathExtension == "mkv")
        #expect(movies.first?.url.scheme == "http")
        let show = try #require(try await client.series().first)
        let episodes = try await client.episodes(show, season: 6, episode: 14)
        #expect(episodes.count == 1)
        #expect(episodes.first?.name.hasSuffix("S06E14") == true)
        #expect(episodes.first?.url.lastPathComponent == "99.mkv")
        #expect(episodes.first?.catalogTMDBID == 1100)
        let parts = try #require(URLComponents(url: client.endpoint("get_series"), resolvingAgainstBaseURL: false))
        #expect(parts.queryItems?.first { $0.name == "username" }?.value == "a&b")
    }
}

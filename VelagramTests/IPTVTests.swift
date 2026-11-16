import Testing
import Foundation
@testable import Velagram

struct IPTVTests {
    @Test func guideDaysCoverFullHistoryAndFutureIncludingMidnightBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3)))
        let first = try #require(calendar.date(byAdding: .day, value: -14, to: today))
        let midnightEnd = try #require(calendar.date(byAdding: .day, value: 16, to: today))
        let programs = [GuideProgram(channelID: "test", title: "History", summary: "", start: first, end: first.addingTimeInterval(3600)),
                        GuideProgram(channelID: "test", title: "Future", summary: "", start: midnightEnd.addingTimeInterval(-3600), end: midnightEnd)]
        let days = GuideDates.availableDays(in: programs, now: today, calendar: calendar)
        #expect(days.first == first)
        #expect(days.last == calendar.date(byAdding: .day, value: 15, to: today))
        #expect(days.count == 30)
        #expect(days.contains(calendar.date(byAdding: .day, value: -1, to: today)!))
        #expect(GuideDates.availableDays(in: [], now: today, calendar: calendar) == [today])
    }

    @Test func guideRefreshRetainsPlayableHistoryAndUsesProviderCorrections() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let channel = LiveChannel(id: "history", name: "History", url: URL(string: "https://example.com/live")!, group: "Test", guideID: "history", archiveDays: 14)
        func program(_ channelID: String = "history", daysAgo: Double, title: String) -> GuideProgram {
            let start = now.addingTimeInterval(-daysAgo * 86400)
            return GuideProgram(channelID: channelID, title: title, summary: "", start: start, end: start.addingTimeInterval(1800))
        }
        let yesterday = program(daysAgo: 1, title: "Yesterday")
        let corrected = program(daysAgo: 2, title: "Corrected")
        let previous = [yesterday, program(daysAgo: 2, title: "Old title"), program(daysAgo: 15, title: "Expired"), program("no-archive", daysAgo: 1, title: "Unavailable"), program(daysAgo: -1, title: "Stale future")]
        let fresh = program(daysAgo: -2, title: "Fresh future")
        let result = GuideDates.retainingCatchupHistory(previous, incoming: [corrected, fresh], channels: [channel], now: now)
        #expect(Set(result.map(\.title)) == ["Yesterday", "Corrected", "Fresh future"])
        #expect(result.contains(yesterday))
        #expect(result.count == 3)
    }

    @Test func channelNameCachesSupportConcurrentParsing() async {
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    for _ in 0..<100 {
                        guard ChannelSources.basicName("ספורט 1 - (גיבוי 2) HD") == "ספורט 1",
                              ChannelSources.basicName("Sport ONE2 - Backup 3") == "Sport ONE2" else { return false }
                    }
                    return true
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 20)
        #expect(results.allSatisfy { $0 })
    }

    @MainActor @Test func liveLineupAndSourceIndexAreReusedAndInvalidateOnEdits() throws {
        let suite = "VelagramTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        store.channels = (0..<200).flatMap { index in
            (0..<4).map { source in
                LiveChannel(id: "cache:\(index):\(source)", name: "Cache Channel \(index)" + (source == 0 ? "" : " (Backup \(source))"), url: URL(string: "https://example.com/\(index)/\(source)")!, group: "Cache Test")
            }
        }
        let first = try #require(store.liveChannels.first { $0.group == "Cache Test" })
        let builds = store.liveLineupBuildCount
        #expect(store.sources(for: first).count == 4)
        let indexBuilds = store.sourceIndexBuildCount
        for _ in 0..<100 {
            #expect(store.liveChannels.filter { $0.group == "Cache Test" }.count == 200)
            #expect(store.sources(for: first).count == 4)
        }
        #expect(store.liveLineupBuildCount == builds)
        #expect(store.sourceIndexBuildCount == indexBuilds)
        store.favorites = ["cache:0:1"]
        #expect(store.isFavorite(first))
        store.favorites = []
        #expect(!store.isFavorite(first))
        store.hiddenCategories.insert("Cache Test")
        #expect(!store.liveChannels.contains { $0.group == "Cache Test" })
        store.hiddenCategories = []
        store.hiddenChannelIDs.insert("cache:0:1")
        #expect(store.sources(for: first).count == 3)
        store.channelOrder = ["cache:199:0", first.id]
        #expect(store.liveChannels.first?.id == "cache:199:0")
        store.combineChannelSources = false
        #expect(store.liveChannels.filter { $0.group == "Cache Test" }.count == 799)
        store.combineChannelSources = true
        store.channels.removeAll { $0.id == "cache:0:2" }
        #expect(store.sources(for: first).count == 2)
        #expect(store.sourceIndexBuildCount == indexBuilds + 1)
    }

    @Test(arguments: [
        ("ספורט 1 - (גיבוי 1)", "ספורט 1"),
        ("ספורט 1 - [גיבוי 2] HD", "ספורט 1"),
        ("Sport ONE-גיבוי", "Sport ONE"),
        ("Sport ONE2-גיבוי", "Sport ONE2"),
        ("BBC One (Backup #2) FHD", "BBC One"),
        ("[Backup 3] Sky Sports 2 UHD", "Sky Sports 2"),
        ("ספורט 1 [גיבוי מספר 2]", "ספורט 1"),
        ("ספורט 1 (מקור חלופי 3)", "ספורט 1"),
        ("BBC One - Backup server 2 Full HD", "BBC One"),
        ("מקור ראשון", "מקור ראשון"),
        ("5 SPORT+", "5 SPORT+")
    ])
    func cleansSourceDecorations(example: (String, String)) {
        #expect(ChannelSources.basicName(example.0) == example.1)
    }

    @MainActor @Test func combinesSourcesAndPersistsDefaultWithoutCombiningChannelNumbers() throws {
        let suite = "VelagramTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        let a = LiveChannel(id: "main", name: "ספורט 1", url: URL(string: "https://example.com/main")!, group: "Test")
        var backup = a; backup.id = "backup"; backup.name = "ספורט 1 - (גיבוי 2)"; backup.url = URL(string: "https://example.com/backup")!
        var other = a; other.id = "other"; other.name = "ספורט 2"
        #expect(ChannelSources.grouped([backup, a]).first?.id == a.id)
        store.channels = [a, backup, other]
        #expect(store.liveChannels.filter { $0.group == "Test" }.map(\.name) == ["ספורט 1", "ספורט 2"])
        #expect(store.sources(for: a).count == 2)
        store.setDefaultSource(backup, for: a)
        let restored = VelagramStore(defaults: defaults)
        #expect(restored.defaultSource(for: a).url == backup.url)
        #expect(restored.defaultSource(for: a).name == a.name)
        #expect(restored.adjacentChannel(to: backup, direction: 1, in: restored.liveChannels.filter { $0.group == "Test" })?.id == other.id)
        restored.combineChannelSources = false; restored.persist()
        #expect(VelagramStore(defaults: defaults).liveChannels.filter { $0.group == "Test" }.count == 3)
    }

    @Test func metadataRequiresCorroborationAndPreservesNumbers() {
        var a = LiveChannel(id: "a", name: "ספורט 1", url: URL(string: "https://example.com/a")!, group: "Test", guideID: "Sport1")
        a.tvgName = "Sport 1"
        var b = a; b.id = "b"; b.name = "Sport 1 - Backup 2"
        #expect(ChannelSources.key(a) == ChannelSources.key(b))
        b.name = "Sport 2"
        #expect(ChannelSources.key(a) != ChannelSources.key(b))
    }

    @MainActor @Test func channelVisibilityAndOrderPersistPerProfile() throws {
        let suite = "VelagramTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        let a = LiveChannel(id: "custom-a", name: "Zebra", url: URL(string: "https://example.com/a")!, group: "Test")
        let b = LiveChannel(id: "custom-b", name: "Alpha", url: URL(string: "https://example.com/b")!, group: "Test")
        store.channels = [a, b]
        store.channelOrder = [b.id, a.id]
        store.hiddenChannelIDs = [a.id]
        store.persist()
        let restored = VelagramStore(defaults: defaults)
        #expect(restored.liveChannels.filter { $0.group == "Test" }.map(\.id) == [b.id])
        restored.hiddenChannelIDs = []
        #expect(restored.liveChannels.filter { $0.group == "Test" }.map(\.id) == [b.id, a.id])
        restored.addProfile("Other")
        restored.switchProfile(try #require(restored.profiles.last))
        #expect(restored.hiddenChannelIDs.isEmpty)
        #expect(restored.channelOrder.isEmpty)
    }

    @MainActor @Test func liveSearchFindsScheduledPrograms() throws {
        let suite = "VelagramTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        let channel = LiveChannel(id: "sports", name: "Arena", url: URL(string: "https://example.com/live")!, group: "Sports", guideID: "arena")
        store.programs = [GuideProgram(channelID: "arena", title: "Evening football", summary: "", start: .now, end: .now.addingTimeInterval(3600))]
        #expect(store.matchesLiveSearch(channel, query: "FOOTBALL"))
        #expect(store.matchesLiveSearch(channel, query: "arena"))
        #expect(!store.matchesLiveSearch(channel, query: "cooking"))
    }

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
        case "get_live_categories": body = #"[{"category_id":"4","category_name":"News"},{"category_id":"7","category_name":"Kids"}]"#
        case "get_live_streams" where URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "category_id" && $0.value == "7" }) == true:
            body = #"[{"stream_id":70,"name":"Kids TV","category_id":"7"}]"#
        case "get_live_streams": body = #"[{"stream_id":12,"name":"World News","category_id":"4","epg_channel_id":"news.tv","tv_archive":1,"tv_archive_duration":"3"},{"stream_id":"13","name":"Another","category_id":4}]"#
        case "get_vod_categories": body = #"[]"#
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

extension IPTVTests {
    @Test func catchupClockRejectsArchiveTimestampDiscontinuities() {
        var clock = CatchupPlaybackClock(position: 1800, uptime: 0)
        #expect(clock.update(time: 20_000, uptime: 0.2) == 1800)
        #expect(clock.update(time: 0.7, uptime: 1) == 1800.7)
        #expect(clock.update(time: 20_000, uptime: 1.2) == 1800.7)
        #expect(clock.update(time: 0.9, uptime: 1.4) == 1800.7)
        #expect(clock.update(time: 1.9, uptime: 2.4) == 1801.7)
        #expect(clock.update(time: .nan, uptime: 3) == 1801.7)
    }
    @Test func serverErrorCannotBecomeFakeChannel() {
        for response in ["Unauthorized", "<html>Access denied</html>", "https://example.com/login", #"{"error":"expired"}"#] {
            #expect(PlaylistParser.parse(response, relativeTo: URL(string: "https://example.com/")).channels.isEmpty)
        }
    }
    @Test func liveAPIMapsCategoriesGuideAndArchive() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IPTVAPIProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let account = IPTVAccount(id: UUID(), server: URL(string: "http://iptv-fixture.test:8080")!, name: "Fixture")
        let client = IPTVOnDemandClient(account: account, credentials: .init(username: "user", password: "pass"), http: VelagramHTTP(session: session))
        let channels = try await client.liveChannels()
        #expect(channels.count == 2)
        #expect(channels.map(\.name) == ["Another", "World News"])
        let channel = try #require(channels.last)
        #expect(channel.group == "News")
        #expect(channel.guideID == "news.tv")
        #expect(channel.accountID == account.id)
        #expect(channel.url.path == "/live/user/pass/12.m3u8")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let program = GuideProgram(channelID: "news.tv", title: "Yesterday", summary: "", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        let replay = try #require(client.catchup(channel, program: program, now: now))
        #expect(replay.url.path.contains("/timeshift/user/pass/60/"))
        #expect(replay.url.lastPathComponent == "12.ts")
        #expect(replay.catchupContext?.channelID == channel.id)
        #expect(replay.catchupContext?.program == program)
        #expect(replay.catchupContext?.duration == 3600)
        let seek = try #require(replay.catchupPlayback(at: 1850.7))
        #expect(seek.offset == 1850)
        #expect(seek.url.path == "/timeshift/user/pass/30/\(Int(program.start.timeIntervalSince1970) + 1850)/12.ts")
        #expect(replay.catchupPlayback(at: -15)?.offset == 0)
        #expect(replay.catchupPlayback(at: 5000)?.offset == 3599)
        #expect(replay.catchupPlayback(at: .nan) == nil)
        #expect(channel.catchupPlayback(at: 100) == nil)
        #expect(replay.id != channel.id)
        #expect(channel.supportsCatchup)
        #expect(!channels[0].supportsCatchup)
        let next = GuideProgram(channelID: program.channelID, title: "Next show", summary: "", start: program.end, end: now)
        let continuation = try #require(client.catchup(channel, program: next, now: now))
        #expect(replay.catchupContext?.nextProgram(in: [next, program]) == next)
        #expect(continuation.catchupContext?.nextProgram(in: [program, next]) == nil)
        #expect(continuation.id != replay.id)
        #expect(continuation.catchupContext?.program.start == program.end)
        let invalid = GuideProgram(channelID: program.channelID, title: "Invalid", summary: "", start: program.end, end: program.start)
        #expect(client.catchup(channel, program: invalid, now: now) == nil)
        #expect(try JSONDecoder().decode(LiveChannel.self, from: JSONEncoder().encode(replay)).catchupContext == replay.catchupContext)
        #expect(client.catchup(channels[0], program: program, now: now) == nil)
        #expect(client.catchup(channel, program: program, now: now.addingTimeInterval(4 * 86400)) == nil)
    }
}

extension IPTVTests {
    @MainActor @Test func guideRetainsHistoryAndDistinguishesNowFromNext() throws {
        let suite = "GuideTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        let now = Date.now
        let channel = LiveChannel(id: "news", name: "News", url: URL(string: "https://example.com/live.m3u8")!, group: "News", guideID: "news.tv")
        let previous = GuideProgram(channelID: "news.tv", title: "Previous", summary: "", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        let current = GuideProgram(channelID: "news.tv", title: "Current", summary: "", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        let next = GuideProgram(channelID: "news.tv", title: "Next", summary: "", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200))
        store.programs = [next, previous, current]
        #expect(store.schedule(channel).map(\.title) == ["Previous", "Current", "Next"])
        #expect(store.now(channel, at: now)?.title == "Current")
        store.programs = [next]
        #expect(store.now(channel, at: now) == nil)
    }
}

extension IPTVTests {
    @MainActor @Test func categoryPreferencesPersistAndHiddenSourcesLeaveScansAndZapping() throws {
        let suite = "CategoryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        let a = LiveChannel(id: "a", name: "A", url: URL(string: "https://example.com/a.m3u8")!, group: "News")
        let b = LiveChannel(id: "b", name: "B", url: URL(string: "https://example.com/b.m3u8")!, group: "Kids")
        let c = LiveChannel(id: "c", name: "C", url: URL(string: "https://example.com/c.m3u8")!, group: "Sports")
        store.channels = [a, b, c]
        store.toggleCategoryFavorite("Sports")
        #expect(store.sortedCategories(["News", "Sports", "Kids"]) == ["Sports", "Kids", "News"])
        store.hideCategory("Kids")
        #expect(!store.iptvProvider().entries.contains { $0.id == "b" })
        #expect(store.adjacentChannel(to: a, direction: 1, in: [a, b, c])?.id == "c")
        #expect(store.adjacentChannel(to: a, direction: -1, in: [a, b, c])?.id == "c")
        let restored = VelagramStore(defaults: defaults)
        #expect(restored.hiddenCategories == ["Kids"])
        #expect(restored.favoriteCategories == ["Sports"])
        restored.restoreCategory("Kids")
        #expect(restored.iptvProvider().entries.count == 3)
        restored.addProfile("Other"); restored.switchProfile(try #require(restored.profiles.last))
        #expect(restored.hiddenCategories.isEmpty && restored.favoriteCategories.isEmpty)
    }
    @Test func xmltvSkipsHiddenProgramsDuringParsing() throws {
        let xml = #"<tv><programme channel="hidden" start="20261109120000 +0200" stop="20261109130000 +0200"><title>Hidden</title></programme><programme channel="visible" start="20261109120000 +0200" stop="20261109130000 +0200"><title>Visible</title></programme></tv>"#
        let programs = try XMLTVParser.parse(Data(xml.utf8), excludingChannelIDs: ["hidden"])
        #expect(programs.map(\.title) == ["Visible"])
    }
    @Test func allHiddenCategoriesDoNotRequestStreams() async throws {
        let client = IPTVOnDemandClient(account: .init(id: UUID(), server: URL(string: "https://example.invalid")!, name: "Test"), credentials: .init(username: "u", password: "p"))
        let rows = try await client.catalogRows("get_live_streams", groups: ["1": "News"], excluding: ["News"])
        #expect(rows.isEmpty)
    }
}

extension IPTVTests {
    @Test func hiddenCategoryRequestsOnlyVisibleCatalogs() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IPTVAPIProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let account = IPTVAccount(id: UUID(), server: URL(string: "http://iptv-fixture.test")!, name: "Fixture")
        let client = IPTVOnDemandClient(account: account, credentials: .init(username: "u", password: "p"), http: VelagramHTTP(session: session))
        let visible = try await client.liveChannels(excluding: ["News"])
        #expect(visible.map(\.name) == ["Kids TV"])
        #expect(visible.first?.group == "Kids")
    }
}

extension IPTVTests {
    @MainActor @Test func bulkChannelMovesPreserveSelectionAndOtherCategories() throws {
        let suite = "BulkChannelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        store.channels = ["a", "b", "c", "d", "e"].enumerated().map { index, id in
            LiveChannel(id: id, name: id, url: URL(string: "https://example.test/\(id).m3u8")!, group: index % 2 == 0 ? "News" : "Kids")
        }
        store.moveChannelSelection(["a", "e"], in: ["a", "c", "e"], toOffset: 3)
        #expect(store.orderedChannels(store.channels).map(\.id) == ["c", "b", "a", "d", "e"])
        store.moveChannelSelection(["a", "e"], in: ["c", "a", "e"], toOffset: 0)
        #expect(store.orderedChannels(store.channels).map(\.id) == ["a", "b", "e", "d", "c"])
        // Moving before the last channel accounts for selected rows removed before the destination.
        store.moveChannelSelection(["a", "e"], in: ["a", "e", "c"], toOffset: 2)
        #expect(store.orderedChannels(store.channels).map(\.id) == ["a", "b", "e", "d", "c"])
        #expect(VelagramStore(defaults: defaults).channelOrder == store.channelOrder)
        store.moveChannelSelection([], in: ["a", "e", "c"], toOffset: 0)
        #expect(store.orderedChannels(store.channels).map(\.id) == ["a", "b", "e", "d", "c"])
    }
    @MainActor @Test func batchMoveHandlesNoncontiguousRowsAndInteriorDestination() throws {
        let suite = "BatchInterior.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VelagramStore(defaults: defaults)
        store.channels = (0..<6).map { LiveChannel(id: String($0), name: String($0), url: URL(string: "https://example.test/\($0)")!, group: "News") }
        store.moveChannelSelection(["1", "4"], in: ["0", "1", "2", "3", "4", "5"], toOffset: 3)
        #expect(store.orderedChannels(store.channels).map(\.id) == ["0", "2", "1", "4", "3", "5"])
    }
}

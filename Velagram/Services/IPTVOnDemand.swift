import Foundation

struct IPTVAccount: Identifiable, Codable, Sendable {
    var id: UUID
    var server: URL
    var name: String
}
struct IPTVCredentials: Codable, Sendable { let username: String; let password: String }
struct IPTVSeries: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let accountID: UUID
    let tmdbID: Int?
}

struct IPTVOnDemandClient: Sendable {
    let account: IPTVAccount
    let credentials: IPTVCredentials
    var http = VelagramHTTP()
    func endpoint(_ action: String, seriesID: String? = nil) -> URL {
        var url = URLComponents(url: account.server.appending(path: "player_api.php"), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "username", value: credentials.username), .init(name: "password", value: credentials.password), .init(name: "action", value: action)]
        if let seriesID { url.queryItems?.append(.init(name: "series_id", value: seriesID)) }
        return url.url!
    }
    func stream(_ id: String, type: String, ext: String) -> URL {
        account.server.appending(path: type).appending(component: credentials.username).appending(component: credentials.password).appending(component: id + "." + ext)
    }
    func json(_ action: String, seriesID: String? = nil) async throws -> Any {
        try JSONSerialization.jsonObject(with: await http.data(endpoint(action, seriesID: seriesID)))
    }
    func movies() async throws -> [LiveChannel] {
        guard let rows = try await json("get_vod_streams") as? [[String: Any]] else { throw VelagramNetworkError.invalidResponse }
        return rows.compactMap { row in
            guard let id = Self.string(row["stream_id"]), let name = row["name"] as? String else { return nil }
            let url = stream(id, type: "movie", ext: row["container_extension"] as? String ?? "mp4")
            var channel = LiveChannel(id: LiveChannel.identity(url.absoluteString), name: name, url: url, group: account.name + " · Movies", logo: (row["stream_icon"] as? String).flatMap(URL.init(string:)))
            channel.contentKind = "movie"; channel.catalogTMDBID = Self.string(row["tmdb"]).flatMap(Int.init)
            return channel
        }
    }
    func series() async throws -> [IPTVSeries] {
        guard let rows = try await json("get_series") as? [[String: Any]] else { throw VelagramNetworkError.invalidResponse }
        return rows.compactMap { row in
            guard let id = Self.string(row["series_id"]), let name = row["name"] as? String else { return nil }
            return IPTVSeries(id: id, name: name, accountID: account.id, tmdbID: Self.string(row["tmdb"]).flatMap(Int.init))
        }
    }
    func episodes(_ series: IPTVSeries, season: Int, episode: Int) async throws -> [LiveChannel] {
        try await allEpisodes(series).filter { entry in
            TelegramClassification.episode(in: entry.name).map { $0.season == season && $0.episode == episode } ?? false
        }
    }
    func allEpisodes(_ series: IPTVSeries) async throws -> [LiveChannel] {
        let response = try await json("get_series_info", seriesID: series.id) as? [String: Any] ?? [:]
        let seasons = response["episodes"] as? [String: [[String: Any]]] ?? [:]
        return seasons.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.flatMap { season in
            (seasons[season] ?? []).compactMap { row -> LiveChannel? in
                guard let number = Self.string(row["episode_num"]).flatMap(Int.init), let id = Self.string(row["id"]) else { return nil }
                let url = stream(id, type: "series", ext: row["container_extension"] as? String ?? "mp4")
                var channel = LiveChannel(id: LiveChannel.identity(url.absoluteString), name: series.name + String(format: " S%02dE%02d", Int(season) ?? 0, number), url: url, group: account.name + " · Series")
                channel.contentKind = "episode"; channel.catalogTMDBID = series.tmdbID
                return channel
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return (value as? NSNumber)?.stringValue
    }
}

struct IPTVPlaybackProvider: PlaybackProvider {
    let entries: [LiveChannel]
    let accounts: [IPTVAccount]
    let series: [IPTVSeries]
    let credentials: [UUID: IPTVCredentials]
    var programs: [GuideProgram] = []
    var id: String { "iptv" }
    static func matches(_ channel: LiveChannel, context: PlaybackLookupContext) -> Bool {
        guard channel.contentKind != nil else { return false }
        let ep = context.request.episode
        if let tmdb = channel.catalogTMDBID, let wanted = context.request.media.tmdbID, tmdb == wanted {
            if let ep { return TelegramClassification.episode(in: channel.name).map { $0.season == ep.seasonNumber && $0.episode == ep.number } ?? false }
            return channel.contentKind == "movie"
        }
        let media = TelegramMedia(chatID: 0, messageID: 0, fileID: nil, name: channel.name, caption: "", date: .distantPast, size: 0, duration: 0, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: channel.url)
        return TelegramCatalogMatching.score(media, context: context) != nil
    }
    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        var matches = entries.filter { Self.matches($0, context: context) }
        for channel in entries where channel.contentKind == nil {
            guard let guideID = channel.guideID, let program = programs.first(where: { $0.channelID == guideID && $0.start <= .now && $0.end > .now }) else { continue }
            var event = channel
            event.name = program.title
            event.contentKind = context.request.episode == nil ? "movie" : "episode"
            if Self.matches(event, context: context) { event.name += " · Live on " + channel.name; matches.append(event) }
        }
        if let ep = context.request.episode {
            let aliases = TelegramCatalogMatching.aliases(context).map(TelegramCatalogMatching.normalized)
            let shows = series.filter { show in
                if let tmdb = show.tmdbID, let wanted = context.request.media.tmdbID { return tmdb == wanted }
                let name = TelegramCatalogMatching.normalized(TelegramClassification.cleanTitle(show.name))
                return aliases.contains(name)
            }
            try await withThrowingTaskGroup(of: [LiveChannel].self) { group in
                for show in shows {
                    guard let account = accounts.first(where: { $0.id == show.accountID }), let login = credentials[account.id] else { continue }
                    group.addTask { (try? await IPTVOnDemandClient(account: account, credentials: login).episodes(show, season: ep.seasonNumber, episode: ep.number)) ?? [] }
                }
                for try await episodes in group { matches += episodes }
            }
        }
        var seen = Set<String>()
        return matches.filter { seen.insert($0.id).inserted }.map { channel in
            PlaybackCandidate(id: "iptv:" + channel.id, preference: .init(providerID: id, serverName: channel.name, audioLanguage: ""), providerName: "IPTV · " + channel.group, subtitleKind: .selectable,
                displayMetadata: .init(origin: "IPTV", quality: TelegramCatalogMatching.matches(#"(?:2160p|1080p|720p|4k)"#, in: channel.name).first?.uppercased(), sizeBytes: nil, container: channel.url.pathExtension.uppercased(), audioLanguage: nil, releaseType: "VOD")) {
                    PlaybackSource(url: channel.url, headers: channel.headers, subtitles: [], preferredPeakBitRate: nil)
                }
        }
    }
}

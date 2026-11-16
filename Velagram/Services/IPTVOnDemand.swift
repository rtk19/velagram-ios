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
    var group: String?
    var cover: URL?
}

struct IPTVOnDemandClient: Sendable {
    let account: IPTVAccount
    let credentials: IPTVCredentials
    var http = VelagramHTTP()
    func endpoint(_ action: String, seriesID: String? = nil, categoryID: String? = nil) -> URL {
        var url = URLComponents(url: account.server.appending(path: "player_api.php"), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "username", value: credentials.username), .init(name: "password", value: credentials.password), .init(name: "action", value: action)]
        if let seriesID { url.queryItems?.append(.init(name: "series_id", value: seriesID)) }
        if let categoryID { url.queryItems?.append(.init(name: "category_id", value: categoryID)) }
        return url.url!
    }
    func stream(_ id: String, type: String, ext: String) -> URL {
        account.server.appending(path: type).appending(component: credentials.username).appending(component: credentials.password).appending(component: id + "." + ext)
    }
    func json(_ action: String, seriesID: String? = nil) async throws -> Any {
        try JSONSerialization.jsonObject(with: await http.data(endpoint(action, seriesID: seriesID)))
    }
    func categories(_ action: String) async throws -> [String: String] {
        guard let rows = try await json(action) as? [[String: Any]] else { throw VelagramNetworkError.invalidResponse }
        return rows.reduce(into: [:]) { result, row in
            if let id = Self.string(row["category_id"]), let name = row["category_name"] as? String { result[id] = name }
        }
    }
    // Request only visible category catalogs when exclusions exist. Keep concurrency bounded.
    func catalogRows(_ action: String, groups: [String: String], excluding hidden: Set<String>) async throws -> [[String: Any]] {
        if !hidden.isEmpty && groups.isEmpty { throw VelagramNetworkError.invalidResponse }
        if hidden.isDisjoint(with: Set(groups.values)) {
            guard let rows = try await json(action) as? [[String: Any]] else { throw VelagramNetworkError.invalidResponse }
            return rows
        }
        let ids = groups.keys.filter { !hidden.contains(groups[$0] ?? "") }.sorted()
        var data: [Data] = []
        for offset in stride(from: 0, to: ids.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(ids[offset..<min(offset + 4, ids.count)])
            data += try await withThrowingTaskGroup(of: Data.self) { group in
                for id in batch {
                    let url = endpoint(action, categoryID: id)
                    group.addTask { try await http.data(url) }
                }
                var results: [Data] = []
                for try await result in group { results.append(result) }
                return results
            }
        }
        return try data.flatMap {
            guard let rows = try JSONSerialization.jsonObject(with: $0) as? [[String: Any]] else { throw VelagramNetworkError.invalidResponse }
            return rows
        }.filter { !hidden.contains(groups[Self.string($0["category_id"]) ?? ""] ?? "") }
    }
    func liveChannels(excluding hidden: Set<String> = []) async throws -> [LiveChannel] {
        let groups = (try? await categories("get_live_categories")) ?? [:]
        let rows = try await catalogRows("get_live_streams", groups: groups, excluding: hidden)
        return rows.compactMap { row in
            guard let id = Self.string(row["stream_id"]), let name = row["name"] as? String else { return nil }
            let url = stream(id, type: "live", ext: "m3u8")
            var channel = LiveChannel(id: LiveChannel.identity(url.absoluteString), name: name, url: url,
                group: groups[Self.string(row["category_id"]) ?? ""] ?? "Live TV",
                logo: (row["stream_icon"] as? String).flatMap(URL.init(string:)),
                guideID: Self.string(row["epg_channel_id"]))
            channel.accountID = account.id
            channel.archiveDays = Self.string(row["tv_archive"]) == "1" ? Self.string(row["tv_archive_duration"]).flatMap(Int.init) : nil
            return channel
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func catchup(_ channel: LiveChannel, program: GuideProgram, now: Date = .now) -> LiveChannel? {
        guard let days = channel.archiveDays, days > 0, program.end > program.start, program.end <= now,
              program.start >= now.addingTimeInterval(-Double(days) * 86400) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        let duration = max(1, Int(ceil(program.end.timeIntervalSince(program.start) / 60)))
        let id = channel.url.deletingPathExtension().lastPathComponent
        var replay = channel
        replay.url = account.server.appending(path: "timeshift").appending(component: credentials.username)
            .appending(component: credentials.password).appending(component: String(duration))
            .appending(component: formatter.string(from: program.start)).appending(component: id + ".ts")
        replay.name = program.title + " · " + channel.name
        replay.id = channel.id + ":" + program.id
        replay.contentKind = "catchup"
        replay.catchupContext = CatchupContext(channelID: channel.id, program: program)
        return replay
    }
    func movies(excluding hidden: Set<String> = []) async throws -> [LiveChannel] {
        let groups = (try? await categories("get_vod_categories")) ?? [:]
        let rows = try await catalogRows("get_vod_streams", groups: groups, excluding: hidden)
        return rows.compactMap { row in
            guard let id = Self.string(row["stream_id"]), let name = row["name"] as? String else { return nil }
            let url = stream(id, type: "movie", ext: row["container_extension"] as? String ?? "mp4")
            var channel = LiveChannel(id: LiveChannel.identity(url.absoluteString), name: name, url: url, group: groups[Self.string(row["category_id"]) ?? ""] ?? "Movies", logo: (row["stream_icon"] as? String).flatMap(URL.init(string:)))
            channel.accountID = account.id
            channel.contentKind = "movie"; channel.catalogTMDBID = Self.string(row["tmdb"]).flatMap(Int.init)
            return channel
        }
    }
    func series(excluding hidden: Set<String> = []) async throws -> [IPTVSeries] {
        let groups = (try? await categories("get_series_categories")) ?? [:]
        let rows = try await catalogRows("get_series", groups: groups, excluding: hidden)
        return rows.compactMap { row in
            guard let id = Self.string(row["series_id"]), let name = row["name"] as? String else { return nil }
            return IPTVSeries(id: id, name: name, accountID: account.id, tmdbID: Self.string(row["tmdb"]).flatMap(Int.init), group: groups[Self.string(row["category_id"]) ?? ""], cover: (row["cover"] as? String).flatMap(URL.init(string:)))
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

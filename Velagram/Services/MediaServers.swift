import Foundation

struct MediaServer: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var url: URL
    var userID: String
    var kind: Kind
    enum Kind: String, Codable, CaseIterable { case jellyfin = "Jellyfin", emby = "Emby" }
}

struct ServerItem: Decodable, Identifiable, Hashable, Sendable {
    let Id: String
    let Name: String
    let mediaType: String?
    let Overview: String?
    let PrimaryImageTag: String?
    let RunTimeTicks: Int64?
    let ImageTags: [String: String]?
    let SeriesId: String?
    let SeriesPrimaryImageTag: String?
    let ParentPrimaryImageItemId: String?
    let ParentPrimaryImageTag: String?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let IndexNumberEnd: Int?
    let ProviderIds: [String: String]?
    let ProductionYear: Int?
    enum CodingKeys: String, CodingKey {
        case Id, Name, mediaType = "Type", Overview, PrimaryImageTag, RunTimeTicks
        case ImageTags, SeriesId, SeriesPrimaryImageTag, ParentPrimaryImageItemId, ParentPrimaryImageTag
        case IndexNumber, ParentIndexNumber, IndexNumberEnd, ProviderIds, ProductionYear
    }
    var detailLabel: String {
        if mediaType == "Episode", let number = IndexNumber {
            let code = ParentIndexNumber.map { "Season \($0) · " } ?? ""
            let end = IndexNumberEnd.flatMap { $0 > number ? "–\($0)" : nil } ?? ""
            return code + "Episode \(number)" + end
        }
        if mediaType == "Season", let number = IndexNumber { return "Season \(number)" }
        return mediaType ?? "Media"
    }
    var id: String { Id }
    var isFolder: Bool { ["CollectionFolder", "Folder", "Series", "Season", "BoxSet", "MusicAlbum", "MusicArtist", "UserView"].contains(mediaType ?? "") }
}

struct MediaServerClient: Sendable {
    let server: MediaServer
    let token: String
    var session: URLSession = .shared
    private var authorization: String {
        "MediaBrowser Client=\"Velagram iOS\", Device=\"iPhone\", DeviceId=\"velagram-ios\", Version=\"1.0.0\", Token=\"\(token)\""
    }
    var headers: [String: String] { ["X-Emby-Token": token, "Authorization": authorization] }

    static func signIn(url: URL, name: String, username: String, password: String, kind: MediaServer.Kind) async throws -> (MediaServer, String) {
        var request = URLRequest(url: url.appending(path: "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MediaBrowser Client=\"Velagram iOS\", Device=\"iPhone\", DeviceId=\"velagram-ios\", Version=\"1.0.0\"", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw VelagramNetworkError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw VelagramNetworkError.http(response.statusCode) }
        let result = try JSONDecoder().decode(Authentication.self, from: data)
        return (MediaServer(id: UUID(), name: name.isEmpty ? kind.rawValue : name, url: url, userID: result.User.Id, kind: kind), result.AccessToken)
    }
    func items(parentID: String? = nil, query: String = "", types: String? = nil, recursive: Bool = false, season: Int? = nil) async throws -> [ServerItem] {
        var result: [ServerItem] = []
        while true {
            try Task.checkCancellation()
            var parameters = [URLQueryItem(name: "Fields", value: "Overview,ProviderIds,PrimaryImageAspectRatio"),
                .init(name: "EnableImages", value: "true"), .init(name: "Limit", value: "500"),
                .init(name: "StartIndex", value: String(result.count)),
                .init(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
                .init(name: "SortOrder", value: "Ascending")]
            if let parentID { parameters.append(.init(name: "ParentId", value: parentID)) }
            if let types { parameters.append(.init(name: "IncludeItemTypes", value: types)) }
            if let season { parameters.append(.init(name: "ParentIndexNumber", value: String(season))) }
            if recursive || !query.isEmpty { parameters.append(.init(name: "Recursive", value: "true")) }
            if !query.isEmpty { parameters.append(.init(name: "SearchTerm", value: query)) }
            struct Page: Decodable { let Items: [ServerItem]; let TotalRecordCount: Int? }
            let page: Page = try await get("Users/\(server.userID)/Items", query: parameters)
            result += page.Items
            if page.Items.isEmpty || result.count >= (page.TotalRecordCount ?? Int.max) || (page.TotalRecordCount == nil && page.Items.count < 500) { return result }
        }
    }
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: server.url.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.allHTTPHeaderFields = headers
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw VelagramNetworkError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw VelagramNetworkError.http(response.statusCode) }
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: data)
    }
    func image(_ item: ServerItem) -> URL? {
        let imageID: String
        let tag: String
        if let own = item.ImageTags?["Primary"] ?? item.PrimaryImageTag { imageID = item.id; tag = own }
        else if let seriesID = item.SeriesId, let seriesTag = item.SeriesPrimaryImageTag { imageID = seriesID; tag = seriesTag }
        else if let parentID = item.ParentPrimaryImageItemId, let parentTag = item.ParentPrimaryImageTag { imageID = parentID; tag = parentTag }
        else { return nil }
        var url = URLComponents(url: server.url.appending(path: "Items/\(imageID)/Images/Primary"), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "maxWidth", value: "400"), .init(name: "tag", value: tag), .init(name: "api_key", value: token)]
        return url.url
    }
    struct PlaybackInfo: Decodable {
        let MediaSources: [MediaSource]?
        let PlaySessionId: String?
        let ErrorCode: String?
    }
    struct MediaSource: Decodable {
        let Id: String
        let Container: String?
        let SupportsDirectPlay: Bool?
        let SupportsDirectStream: Bool?
        let TranscodingUrl: String?
        let DirectStreamUrl: String?
        let RequiredHttpHeaders: [String: String]?
    }
    enum PlaybackError: LocalizedError {
        case unavailable(String?)
        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return "The server could not provide a compatible stream" + (reason.map { " (\($0))" } ?? "") + ". Check that this user is allowed to play and transcode this item."
            }
        }
    }

    // Ask the server to select a source and build its stream URL, including its
    // codec, media source, session and transcoding parameters.
    func playbackSource(_ item: ServerItem) async throws -> PlaybackSource {
        let profile: [String: Any] = [
            "Name": "Velagram iOS", "MaxStreamingBitrate": 20_000_000,
            "DirectPlayProfiles": [
                ["Type": "Video", "Container": "mp4,m4v", "VideoCodec": "h264", "AudioCodec": "aac,mp3"],
                ["Type": "Audio", "Container": "mp3,aac,m4a", "AudioCodec": "aac,mp3"]
            ],
            "TranscodingProfiles": [
                ["Type": "Video", "Container": "ts", "Protocol": "hls", "VideoCodec": "h264", "AudioCodec": "aac", "MaxAudioChannels": "2", "Context": "Streaming", "MinSegments": 2, "BreakOnNonKeyFrames": true],
                ["Type": "Audio", "Container": "mp3", "Protocol": "http", "AudioCodec": "mp3", "Context": "Streaming"]
            ],
            "CodecProfiles": [
                ["Type": "Video", "Codec": "h264", "Conditions": [
                    ["Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": true],
                    ["Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "51", "IsRequired": true]
                ]]
            ]
        ]
        var request = URLRequest(url: server.url.appending(path: "Items/\(item.id)/PlaybackInfo"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.allHTTPHeaderFields = headers
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "UserId": server.userID, "DeviceId": "velagram-ios", "IsPlayback": true,
            "StartTimeTicks": 0, "MaxStreamingBitrate": 20_000_000,
            "EnableDirectPlay": true, "EnableDirectStream": true, "EnableTranscoding": true,
            "AutoOpenLiveStream": true, "DeviceProfile": profile
        ])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw VelagramNetworkError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw VelagramNetworkError.http(response.statusCode) }
        try Task.checkCancellation()
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: data)
        guard info.ErrorCode == nil else { throw PlaybackError.unavailable(info.ErrorCode) }
        for source in info.MediaSources ?? [] {
            let url: URL
            if source.SupportsDirectPlay == true {
                let ext = source.Container?.split(separator: ",").first.map(String.init) ?? "mp4"
                let type = item.mediaType == "Audio" ? "Audio" : "Videos"
                url = server.url.appending(path: "\(type)/\(item.id)/stream.\(ext)")
            } else if source.SupportsDirectStream == true, let direct = source.DirectStreamUrl, !direct.isEmpty {
                url = try playbackURL(direct)
            } else if let transcode = source.TranscodingUrl, !transcode.isEmpty {
                url = try playbackURL(transcode)
            } else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var query = components.queryItems ?? []
            func add(_ name: String, _ value: String?) {
                guard let value, !query.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
                query.append(.init(name: name, value: value))
            }
            add("api_key", token)
            add("MediaSourceId", source.Id)
            add("PlaySessionId", info.PlaySessionId)
            add("DeviceId", "velagram-ios")
            if source.SupportsDirectPlay == true { add("Static", "true") }
            components.queryItems = query
            var streamHeaders = headers
            streamHeaders.merge(source.RequiredHttpHeaders ?? [:]) { _, required in required }
            return PlaybackSource(url: components.url!, headers: streamHeaders, subtitles: [], preferredPeakBitRate: nil)
        }
        throw PlaybackError.unavailable(nil)
    }

    private func playbackURL(_ value: String) throws -> URL {
        guard let parsed = URL(string: value) else { throw VelagramNetworkError.invalidResponse }
        if let scheme = parsed.scheme {
            guard ["http", "https"].contains(scheme.lowercased()) else { throw VelagramNetworkError.invalidResponse }
            return parsed
        }
        // Server responses can include the configured reverse-proxy base path,
        // or be relative to it. Preserve that prefix exactly once.
        let basePath = server.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !basePath.isEmpty && (path.hasPrefix(basePath + "/")) {
            var origin = URLComponents(url: server.url, resolvingAgainstBaseURL: false)!
            origin.path = "/"; origin.query = nil; origin.fragment = nil
            guard let url = URL(string: path, relativeTo: origin.url!)?.absoluteURL else { throw VelagramNetworkError.invalidResponse }
            return url
        }
        let base = server.url.appendingPathComponent("").absoluteString
        guard let url = URL(string: path, relativeTo: URL(string: base))?.absoluteURL else { throw VelagramNetworkError.invalidResponse }
        return url
    }
}

struct MediaServerPlaybackProvider: PlaybackProvider {
    let client: MediaServerClient
    var id: String { "server:" + client.server.id.uuidString }

    static func matches(_ item: ServerItem, context: PlaybackLookupContext) -> Bool {
        let wanted = context.request.media
        if let tmdb = item.ProviderIds?.first(where: { $0.key.lowercased() == "tmdb" })?.value,
           let wantedID = wanted.tmdbID { return tmdb == String(wantedID) }
        if let imdb = item.ProviderIds?.first(where: { $0.key.lowercased() == "imdb" })?.value,
           let wantedID = wanted.imdbID { return imdb == wantedID }
        let title = TelegramCatalogMatching.normalized(item.Name)
        guard context.titles.contains(where: { TelegramCatalogMatching.normalized($0) == title }) else { return false }
        if let year = item.ProductionYear, let wantedYear = wanted.releaseDate.flatMap({ Int($0.prefix(4)) }) {
            return year == wantedYear
        }
        return true
    }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        var found: [ServerItem] = []
        var seen = Set<String>()
        var searched = Set<String>()
        let titles = context.titles.filter { searched.insert(TelegramCatalogMatching.normalized($0)).inserted }
        // Search a bounded batch of aliases together so a slow title query does
        // not delay the original-title match. Never negotiate streams here.
        for offset in stride(from: 0, to: titles.count, by: 3) {
            let batch = Array(titles[offset..<min(offset + 3, titles.count)])
            let matches = try await withTaskGroup(of: Result<[ServerItem], Error>.self, returning: Result<[ServerItem], Error>.self) { group in
                for title in batch {
                    group.addTask {
                        do {
                            return .success(try await client.items(query: title, types: context.request.episode == nil ? "Movie" : "Series")
                                .filter { Self.matches($0, context: context) })
                        } catch { return .failure(error) }
                    }
                }
                var failure: Error?
                var succeeded = false
                for await result in group {
                    switch result {
                    case .success(let items):
                        succeeded = true
                        if !items.isEmpty { group.cancelAll(); return Result.success(items) }
                    case .failure(let error): failure = error
                    }
                }
                if !succeeded, let failure { return .failure(failure) }
                return .success([])
            }.get()
            found += matches.filter { seen.insert($0.id).inserted }
            if !found.isEmpty { break }
        }
        if let episode = context.request.episode {
            var episodes: [ServerItem] = []
            for show in found {
                episodes += try await client.items(parentID: show.id, types: "Episode", recursive: true, season: episode.seasonNumber).filter { item in
                    item.ParentIndexNumber == episode.seasonNumber && item.IndexNumber.map { start in
                        start <= episode.number && episode.number <= (item.IndexNumberEnd ?? start)
                    } == true
                }
            }
            found = episodes
        }
        return found.map { item in
            PlaybackCandidate(id: id + ":" + item.id,
                preference: .init(providerID: id, serverName: item.Name + " · " + item.detailLabel, audioLanguage: ""),
                providerName: client.server.kind.rawValue + " · " + client.server.name, subtitleKind: .unknown,
                sourceIdentity: client.server.kind == .jellyfin ? .jellyfin : .emby) {
                    try await client.playbackSource(item)
                }
        }
    }
}

extension MediaServerClient {
    struct QuickConnect: Decodable, Sendable {
        let Code: String
        let Secret: String
        let Authenticated: Bool
    }
    struct Authentication: Decodable {
        let AccessToken: String
        let User: UserInfo
        struct UserInfo: Decodable { let Id: String }
    }
    static func quickRequest<T: Decodable>(url: URL, path: String, method: String = "GET", secret: String? = nil, session: URLSession = .shared) async throws -> T {
        var components = URLComponents(url: url.appending(path: path), resolvingAgainstBaseURL: false)!
        if method == "GET", let secret { components.queryItems = [.init(name: "Secret", value: secret)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("MediaBrowser Client=\"Velagram iOS\", Device=\"iPhone\", DeviceId=\"velagram-ios\", Version=\"1.0.0\"", forHTTPHeaderField: "Authorization")
        if method == "POST", let secret {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["Secret": secret])
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw VelagramNetworkError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw VelagramNetworkError.http(response.statusCode) }
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum XtreamClient {
    static func playlist(server: URL, username: String, password: String) -> URL {
        var url = URLComponents(url: server.appending(path: "get.php"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "type", value: "m3u_plus"), URLQueryItem(name: "output", value: "m3u8")]
        return url.url!
    }
    static func guide(server: URL, username: String, password: String) -> URL {
        var url = URLComponents(url: server.appending(path: "xmltv.php"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        return url.url!
    }
}

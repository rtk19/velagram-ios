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
    enum CodingKeys: String, CodingKey { case Id, Name, mediaType = "Type", Overview, PrimaryImageTag, RunTimeTicks }
    var id: String { Id }
    var isFolder: Bool { ["CollectionFolder", "Folder", "Series", "Season", "BoxSet", "MusicAlbum", "MusicArtist", "UserView"].contains(mediaType ?? "") }
}

struct MediaServerClient: Sendable {
    let server: MediaServer
    let token: String
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
        struct Authentication: Decodable { let AccessToken: String; let User: UserInfo
            struct UserInfo: Decodable { let Id: String }
        }
        let result = try JSONDecoder().decode(Authentication.self, from: data)
        return (MediaServer(id: UUID(), name: name.isEmpty ? kind.rawValue : name, url: url, userID: result.User.Id, kind: kind), result.AccessToken)
    }
    func items(parentID: String? = nil, query: String = "") async throws -> [ServerItem] {
        var url = URLComponents(url: server.url.appending(path: "Users/\(server.userID)/Items"), resolvingAgainstBaseURL: false)!
        var parameters = [URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio"), URLQueryItem(name: "Limit", value: "500"), URLQueryItem(name: "SortBy", value: "SortName")]
        if let parentID { parameters.append(URLQueryItem(name: "ParentId", value: parentID)) }
        if !query.isEmpty { parameters += [URLQueryItem(name: "SearchTerm", value: query), URLQueryItem(name: "Recursive", value: "true")] }
        url.queryItems = parameters
        let data = try await VelagramHTTP().data(url.url!, headers: headers)
        struct Page: Decodable { let Items: [ServerItem] }
        return try JSONDecoder().decode(Page.self, from: data).Items
    }
    func image(_ item: ServerItem) -> URL? {
        guard item.PrimaryImageTag != nil else { return nil }
        var url = URLComponents(url: server.url.appending(path: "Items/\(item.id)/Images/Primary"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "maxWidth", value: "400"), URLQueryItem(name: "api_key", value: token)]
        return url.url
    }
    func stream(_ item: ServerItem) -> URL {
        var url = URLComponents(url: server.url.appending(path: "Videos/\(item.id)/master.m3u8"), resolvingAgainstBaseURL: false)!
        if item.mediaType == "Audio" { url = URLComponents(url: server.url.appending(path: "Audio/\(item.id)/stream"), resolvingAgainstBaseURL: false)! }
        url.queryItems = [URLQueryItem(name: "api_key", value: token), URLQueryItem(name: "UserId", value: server.userID),
            URLQueryItem(name: "VideoCodec", value: "h264"), URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "MaxStreamingBitrate", value: "20000000")]
        return url.url!
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

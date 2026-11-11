import Foundation

struct TelegramChat: Identifiable, Hashable, Sendable {
    let id: Int64
    var title: String
    var kind: String
    var isForum: Bool
    var photoFileID: Int?
    init?(_ json: TelegramJSON) {
        guard let id = json["id"].int64 else { return nil }
        self.id = id; title = json["title"].string ?? "Chat"
        kind = json["type"].type; isForum = json["view_as_topics"].bool || json["type"]["is_forum"].bool
        photoFileID = json["photo"]["small"]["id"].int64.map(Int.init)
    }
}
struct TelegramFolder: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
}
struct TelegramTopic: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
}

enum TelegramCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case all = "All", movies = "Movies", series = "Series"
    var id: Self { self }
}
enum TelegramSort: String, CaseIterable, Identifiable {
    case newest = "Newest first", oldest = "Oldest first", title = "Title A–Z", episode = "Episode order", size = "Largest first"
    var id: Self { self }
}
struct TelegramEpisode: Codable, Hashable, Sendable {
    let season: Int
    let episode: Int
}
struct TelegramFile: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    var size: Int64
    var localPath: String
    var downloadedSize: Int64
    var downloadOffset: Int64
    var downloadedPrefixSize: Int64
    var completed: Bool
    var downloading: Bool
    init?(_ json: TelegramJSON) {
        guard let id = json["id"].int64 else { return nil }
        self.id = Int(id); size = max(json["size"].int64 ?? 0, json["expected_size"].int64 ?? 0)
        let local = json["local"]
        localPath = local["path"].string ?? ""; downloadedSize = local["downloaded_size"].int64 ?? 0
        downloadOffset = local["download_offset"].int64 ?? 0
        downloadedPrefixSize = local["downloaded_prefix_size"].int64 ?? 0
        completed = local["is_downloading_completed"].bool; downloading = local["is_downloading_active"].bool
    }
}
struct TelegramMedia: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(chatID):\(messageID)" }
    let chatID: Int64
    let messageID: Int64
    let fileID: Int?
    let name: String
    let caption: String
    let date: Date
    let size: Int64
    let duration: Int
    let mimeType: String
    let thumbnailFileID: Int?
    let kind: Kind
    let remoteURL: URL?
    var remoteUniqueID: String? = nil
    enum Kind: String, Codable, Sendable { case video, audio, document, photo, link }
    var episode: TelegramEpisode? { TelegramClassification.episode(in: name + " " + caption) }
    var title: String { TelegramClassification.cleanTitle(name) }
    var seriesKey: String { title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
    var isVideo: Bool { kind == .video || ["mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts"].contains((name as NSString).pathExtension.lowercased()) || mimeType.hasPrefix("video/") }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    static func parse(_ message: TelegramJSON) -> TelegramMedia? {
        guard let chatID = message["chat_id"].int64, let messageID = message["id"].int64 else { return nil }
        let content = message["content"]
        let media: TelegramJSON
        let file: TelegramJSON
        let kind: Kind
        switch content.type {
        case "messageVideo": media = content["video"]; file = media["video"]; kind = .video
        case "messageDocument": media = content["document"]; file = media["document"]; kind = .document
        case "messageAudio": media = content["audio"]; file = media["audio"]; kind = .audio
        case "messageAnimation": media = content["animation"]; file = media["animation"]; kind = .video
        case "messagePhoto":
            media = content["photo"]; file = media["sizes"].array.last?["photo"] ?? .null; kind = .photo
        case "messageText":
            let text = content["text"]["text"].string ?? ""
            let urls = content["text"]["entities"].array.compactMap { $0["type"]["url"].string }
            let pattern = #"https?://[^\s<>\"]+"#
            let regex = try? NSRegularExpression(pattern: pattern)
            let matched = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } } ?? []
            guard let url = (urls + matched).compactMap(URL.init(string:)).first(where: { ["m3u8", "mp4", "mkv", "mp3", "m4v", "mov", "m3u"].contains($0.pathExtension.lowercased()) }) else { return nil }
            return TelegramMedia(chatID: chatID, messageID: messageID, fileID: nil, name: url.lastPathComponent, caption: text,
                date: Date(timeIntervalSince1970: Double(message["date"].int64 ?? 0)), size: 0, duration: 0,
                mimeType: "", thumbnailFileID: nil, kind: .link, remoteURL: url)
        default: return nil
        }
        guard let fileID = file["id"].int64 else { return nil }
        let caption = content["caption"]["text"].string ?? ""
        let fallback = caption.components(separatedBy: .newlines).first.flatMap { $0.isEmpty ? nil : $0 } ?? "Media \(messageID)"
        let name = media["file_name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return TelegramMedia(chatID: chatID, messageID: messageID, fileID: Int(fileID), name: name, caption: caption,
            date: Date(timeIntervalSince1970: Double(message["date"].int64 ?? 0)), size: max(file["size"].int64 ?? 0, file["expected_size"].int64 ?? 0),
            duration: media["duration"].int, mimeType: media["mime_type"].string ?? "", thumbnailFileID: media["thumbnail"]["file"]["id"].int64.map(Int.init), kind: kind, remoteURL: nil, remoteUniqueID: file["remote"]["unique_id"].string)
    }
}

enum TelegramClassification {
    static let episodePatterns = [
        #"(?i)(?<![A-Za-z0-9])S[\s.,_:\-]*(\d{1,3})[\s.,_:\-]*E[\s.,_:\-]*(\d{1,4})(?!\d)"#,
        #"(?i)(?<![A-Za-z0-9])(\d{1,2})[ ._\-]*x[ ._\-]*(\d{1,4})(?!\d)"#,
        #"ע(?:ונה)?[\s.,_:\-]*(\d{1,3})[\s.,_:\-]*פ(?:רק)?[\s.,_:\-]*(\d{1,4})(?!\d)"#,
        #"(?i)season[\s.,_:\-]*(\d{1,3})[\s.,_:\-]*episode[\s.,_:\-]*(\d{1,4})(?!\d)"#
    ]
    static func episode(in text: String) -> TelegramEpisode? {
        for pattern in episodePatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let s = Range(match.range(at: 1), in: text), let e = Range(match.range(at: 2), in: text), let season = Int(text[s]), let episode = Int(text[e]) else { continue }
            return TelegramEpisode(season: season, episode: episode)
        }
        return nil
    }
    static func category(_ item: TelegramMedia, chatTitle: String = "", override: TelegramCategory? = nil) -> TelegramCategory {
        if let override, override != .all { return override }
        guard item.isVideo || item.kind == .link else { return .all }
        if item.episode != nil { return .series }
        let hint = chatTitle.lowercased()
        if ["series", "סדרות", "סדרה", "مسلسلات", "сериал"].contains(where: hint.contains) { return .series }
        return .movies
    }
    static func cleanTitle(_ name: String) -> String {
        var title = name
        if ["mp4", "mkv", "mov", "avi", "m4v", "ts", "webm", "mp3", "flac"].contains((name as NSString).pathExtension.lowercased()) { title = (name as NSString).deletingPathExtension }
        for pattern in episodePatterns { title = title.replacingOccurrences(of: pattern + ".*$", with: "", options: .regularExpression) }
        title = title.replacingOccurrences(of: #"(?i)\b(?:19\d{2}|20\d{2}|2160p|1080p|720p|480p|4k|WEB[- .]?DL|WEBRip|BluRay|HDTV|x26[45]|HEVC|AAC|DTS|DDP\d?(?:\.\d)?|REPACK|REMUX)\b.*$"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-[]()")))
        return title.isEmpty ? name : title
    }
    static func sorted(_ items: [TelegramMedia], by sort: TelegramSort) -> [TelegramMedia] {
        items.sorted { left, right in
            switch sort {
            case .newest: if left.date != right.date { return left.date > right.date }
            case .oldest: if left.date != right.date { return left.date < right.date }
            case .title: if left.title != right.title { return left.title.localizedStandardCompare(right.title) == .orderedAscending }
            case .size: if left.size != right.size { return left.size > right.size }
            case .episode:
                let l = left.episode ?? TelegramEpisode(season: Int.max, episode: Int.max)
                let r = right.episode ?? TelegramEpisode(season: Int.max, episode: Int.max)
                if left.seriesKey != right.seriesKey { return left.seriesKey.localizedStandardCompare(right.seriesKey) == .orderedAscending }
                if l.season != r.season { return l.season < r.season }
                if l.episode != r.episode { return l.episode < r.episode }
            }
            return left.id < right.id
        }
    }
}

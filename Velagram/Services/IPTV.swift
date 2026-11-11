import Foundation
import CryptoKit

struct LiveChannel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var url: URL
    var group: String
    var logo: URL?
    var guideID: String?
    var headers: [String: String] = [:]
    var isRadio = false
    var bundledImage: String?
    var contentKind: String?
    var catalogTMDBID: Int?
    var resolver: String?
    var resolverData: [String: String]?

    static func identity(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct PlaylistImport: Sendable {
    var channels: [LiveChannel]
    var guideURL: URL?
}

enum PlaylistParser {
    static func parse(_ text: String, relativeTo base: URL? = nil) -> PlaylistImport {
        var channels: [LiveChannel] = []
        var attributes: [String: String] = [:]
        var name: String?
        var group = "IPTV"
        var headers: [String: String] = [:]
        var guideURL: URL?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{feff}", with: "")
            if line.hasPrefix("#EXTM3U") {
                let attrs = parseAttributes(line)
                if let value = attrs["url-tvg"] ?? attrs["x-tvg-url"] { guideURL = URL(string: value, relativeTo: base)?.absoluteURL }
            } else if line.hasPrefix("#EXTINF:") {
                attributes = parseAttributes(line)
                // Commas in quoted attributes are not the title separator.
                var quoted = false
                var separator: String.Index?
                for i in line.indices {
                    if line[i] == "\"" { quoted.toggle() }
                    if line[i] == ",", !quoted { separator = i; break }
                }
                name = separator.map { String(line[line.index(after: $0)...]) } ?? attributes["tvg-name"]
                group = attributes["group-title"] ?? "IPTV"
                headers = [:]
            } else if line.hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8))
            } else if line.hasPrefix("#EXTVLCOPT:http-referrer=") {
                headers["Referer"] = String(line.dropFirst("#EXTVLCOPT:http-referrer=".count))
            } else if line.hasPrefix("#EXTVLCOPT:http-user-agent=") {
                headers["User-Agent"] = String(line.dropFirst("#EXTVLCOPT:http-user-agent=".count))
            } else if !line.isEmpty, !line.hasPrefix("#") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard let url = URL(string: parts[0], relativeTo: base)?.absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { name = nil; continue }
                if parts.count > 1 {
                    for pair in parts[1].components(separatedBy: "&") {
                        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                        if kv.count == 2 { headers[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
                    }
                }
                var entry = LiveChannel(id: LiveChannel.identity(url.absoluteString), name: name ?? url.lastPathComponent,
                    url: url, group: group, logo: attributes["tvg-logo"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL },
                    guideID: attributes["tvg-id"], headers: headers, isRadio: attributes["radio"] == "true")
                let type = attributes["tvg-type"]?.lowercased() ?? attributes["type"]?.lowercased() ?? ""
                let words = group.lowercased()
                if url.path.contains("/series/") || ["series", "episode"].contains(type) || words.contains("series") || words.contains("סדרות") {
                    entry.contentKind = "episode"
                } else if url.path.contains("/movie/") || ["movie", "vod"].contains(type) || words.contains("vod") || words.contains("movies") || words.contains("סרטים") || ["mp4", "mkv", "avi", "m4v", "mov"].contains(url.pathExtension.lowercased()) {
                    entry.contentKind = TelegramClassification.episode(in: entry.name) == nil ? "movie" : "episode"
                }
                channels.append(entry)
                name = nil; attributes = [:]; headers = [:]
            }
        }
        var seen = Set<String>()
        return PlaylistImport(channels: channels.filter { seen.insert($0.id).inserted }, guideURL: guideURL)
    }

    static func parseAttributes(_ line: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([\w-]+)\s*=\s*"([^"]*)""#) else { return [:] }
        let source = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: source.length)).reduce(into: [:]) { result, match in
            result[source.substring(with: match.range(at: 1))] = source.substring(with: match.range(at: 2))
        }
    }
}

enum VelagramNetworkError: LocalizedError {
    case invalidURL, http(Int), emptyPlaylist, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a complete HTTP or HTTPS address."
        case .http(let code): "The server returned HTTP \(code). Check the address and account access."
        case .emptyPlaylist: "No playable HTTP streams were found in this playlist."
        case .invalidResponse: "The server returned an unexpected response."
        }
    }
}

struct VelagramHTTP: Sendable {
    var session: URLSession = .shared
    func data(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VelagramNetworkError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw VelagramNetworkError.http(http.statusCode) }
        try Task.checkCancellation()
        return data
    }
    static func url(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw VelagramNetworkError.invalidURL }
        return url
    }
}

struct GuideProgram: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(channelID):\(start.timeIntervalSince1970)" }
    let channelID: String
    let title: String
    let summary: String
    let start: Date
    let end: Date
}

final class XMLTVParser: NSObject, XMLParserDelegate {
    private var programs: [GuideProgram] = []
    private var attributes: [String: String] = [:]
    private var title = ""
    private var summary = ""
    private var element = ""
    private var inProgram = false

    static func parse(_ data: Data) throws -> [GuideProgram] {
        let delegate = XMLTVParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? VelagramNetworkError.invalidResponse }
        return delegate.programs.sorted { $0.start < $1.start }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
        element = name
        if name == "programme" { attributes = attrs; title = ""; summary = ""; inProgram = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inProgram else { return }
        if element == "title" { title += string }
        if element == "desc" { summary += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "programme" {
            if let channel = attributes["channel"], let start = Self.date(attributes["start"]), let end = Self.date(attributes["stop"]), end > start {
                programs.append(GuideProgram(channelID: channel, title: title, summary: summary, start: start, end: end))
            }
            inProgram = false
        }
        element = ""
    }
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = text.contains(" ") ? "yyyyMMddHHmmss Z" : "yyyyMMddHHmmss"
        return formatter.date(from: text)
    }
}

enum BundledChannels {
    private struct Entry: Decodable {
        let index: Int?
        let name: String
        let module: String?
        let image: String?
        let type: String?
        let tvgID: String?
        let linkDetails: Link?
        struct Link: Decodable { let link: String?; let host: String?; let referer: String?; let live: String?; let regex: String?; let ch: String?; let cdn: String? }
    }
    static func load() -> [LiveChannel] {
        guard let url = Bundle.main.url(forResource: "channels", withExtension: "json"),
              let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [] }
        return entries.sorted { ($0.value.index ?? 999, $0.key) < ($1.value.index ?? 999, $1.key) }.compactMap { key, entry in
            guard let link = entry.linkDetails?.link ?? entry.linkDetails?.live,
                  let url = URL(string: link, relativeTo: (entry.linkDetails?.host ?? (entry.module == "keshet" ? "https://mako-streaming.akamaized.net" : "")).isEmpty ? nil : URL(string: entry.linkDetails?.host ?? "https://mako-streaming.akamaized.net"))?.absoluteURL,
                  ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
            return LiveChannel(id: "idan:\(key)", name: entry.name, url: url,
                group: entry.type == "radio" ? "Israeli Radio" : "Israeli TV", guideID: entry.tvgID,
                headers: entry.linkDetails?.referer.map { ["Referer": $0] } ?? [:],
                isRadio: entry.type == "radio", bundledImage: entry.image, resolver: entry.module,
                resolverData: ["regex": entry.linkDetails?.regex ?? "", "ch": entry.linkDetails?.ch ?? "", "cdn": entry.linkDetails?.cdn ?? "AKAMAI"])
        }
    }
}

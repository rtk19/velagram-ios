import Foundation
import CryptoKit
import os

struct LiveChannel: Identifiable, Codable, Hashable, Sendable {
    var id: String
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
    var accountID: UUID?
    var catchupContext: CatchupContext?
    var supportsCatchup: Bool { (archiveDays ?? 0) > 0 }
    var archiveDays: Int?
    var resolver: String?
    var resolverData: [String: String]?
    var tvgName: String?

    /// Xtream archives are continuous transport streams. Seeking requires a
    /// fresh archive request, rather than a byte/time seek on the existing feed.
    func catchupPlayback(at seconds: Double) -> (url: URL, offset: Double)? {
        guard let context = catchupContext, seconds.isFinite,
              context.duration > 0, !url.isFileURL,
              url.pathComponents.contains("timeshift") else { return nil }
        let offset = floor(min(max(0, seconds), max(0, context.duration - 1)))
        let start = Int(context.program.start.addingTimeInterval(offset).timeIntervalSince1970)
        let minutes = max(1, Int(ceil((context.duration - offset) / 60)))
        let stream = url.lastPathComponent
        let root = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (root.appending(component: String(minutes)).appending(component: String(start)).appending(component: stream), offset)
    }

    static func identity(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Conservative matching: channel numbers, +/Plus, regional names and languages
/// remain part of identity. Only explicit source/quality decorations are removed.
enum ChannelSources {
    /// Synchronous, bounded storage shared by foreground and background parsing.
    /// The lock owns all mutable state, so no unchecked Sendable conformance is needed.
    private struct NameCache: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: [String: String]())
        func value(for name: String) -> String? {
            storage.withLock { $0[name] }
        }
        func insert(_ value: String, for name: String) {
            storage.withLock { entries in
                if entries.count >= 20_000 { entries.removeAll(keepingCapacity: true) }
                entries[name] = value
            }
        }
    }
    private static let cleanedNames = NameCache()
    private static let normalizedNames = NameCache()
    private static let decorationPatterns: [NSRegularExpression] = {
        let marker = "(?:מקור\\s+חלופי|גיבויים|גיבוי|חלופי|חלופית|backup|back[ -]?up|bkup|alternate|alternative|mirror|(?:מקור|source)(?=\\s*[:#._-]?\\s*[0-9]))"
        return [
            "(?i)(?<![\\p{L}\\p{N}])" + marker + "\\s*(?:(?:מספר|number|no[.]?|server)\\s*)?[:#._-]?\\s*[0-9]*(?![\\p{L}\\p{N}])",
            "(?i)(?<![\\p{L}\\p{N}])(?:full[ -]?hd|ultra[ -]?hd|4k|8k|uhd|fhd|hd|sd|hevc|h[.]?26[45]|1080[pi]?|720p|2160p|50fps|60fps)(?![\\p{L}\\p{N}])"
        ]
            .compactMap { try? NSRegularExpression(pattern: $0) }
    }()
    private static let directionMarks = try! NSRegularExpression(pattern: "[\\u200E\\u200F\\u202A-\\u202E\\u2066-\\u2069]")
    private static let emptyBrackets = try! NSRegularExpression(pattern: #"\(\s*\)|\[\s*\]|\{\s*\}"#)
    private static let whitespace = try! NSRegularExpression(pattern: "\\s+")
    private static let identitySeparators = try! NSRegularExpression(pattern: "[\\s_-]+")
    private static func replace(_ regex: NSRegularExpression, in value: String, with replacement: String) -> String {
        regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }
    static func basicName(_ name: String) -> String {
        if let cached = cleanedNames.value(for: name) { return cached }
        var value = replace(directionMarks, in: name.precomposedStringWithCompatibilityMapping, with: "")
        for pattern in decorationPatterns { value = replace(pattern, in: value, with: " ") }
        value = replace(emptyBrackets, in: value, with: " ")
        value = replace(whitespace, in: value, with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|:._()[]{}")))
        let result = value.isEmpty ? name : value
        cleanedNames.insert(result, for: name)
        return result
    }
    private static func normalized(_ name: String) -> String {
        if let cached = normalizedNames.value(for: name) { return cached }
        let folded = basicName(name).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let result = replace(identitySeparators, in: folded, with: "")
        normalizedNames.insert(result, for: name)
        return result
    }
    static func identityName(_ channel: LiveChannel) -> String {
        let cleaned = basicName(channel.name)
        if let metadata = channel.tvgName, !metadata.isEmpty {
            let candidate = basicName(metadata)
            let digits = { (value: String) in value.filter(\.isNumber) }
            // Require corroboration; providers sometimes reuse one guide ID for
            // an entire category. Numbers must never collapse into another channel.
            if digits(cleaned) == digits(candidate),
               normalized(cleaned) == normalized(candidate) ||
                channel.guideID.map({ normalized($0) == normalized(candidate) }) == true {
                return candidate
            }
        }
        return cleaned
    }
    static func key(_ channel: LiveChannel) -> String {
        // Category boundaries prevent accidental merging of regional feeds.
        "\(channel.isRadio)|\(channel.group.lowercased())|\(normalized(identityName(channel)))"
    }
    static func grouped(_ channels: [LiveChannel]) -> [LiveChannel] {
        var positions: [String: Int] = [:]
        var representatives: [LiveChannel] = []
        func score(_ channel: LiveChannel) -> Int {
            (channel.name == basicName(channel.name) ? 8 : 0) +
                (channel.guideID?.isEmpty == false ? 2 : 0) + (channel.supportsCatchup ? 1 : 0)
        }
        for channel in channels {
            guard channel.contentKind == nil else { representatives.append(channel); continue }
            let identity = key(channel)
            if let index = positions[identity] {
                if score(channel) > score(representatives[index]) { representatives[index] = channel }
            } else {
                positions[identity] = representatives.count
                representatives.append(channel)
            }
        }
        return representatives.map { channel in
            var result = channel
            if channel.contentKind == nil { result.name = identityName(channel) }
            return result
        }
    }
}

struct CatchupContext: Codable, Hashable, Sendable {
    let channelID: String
    let program: GuideProgram
    var duration: Double { program.end.timeIntervalSince(program.start) }
    func nextProgram(in schedule: [GuideProgram]) -> GuideProgram? {
        schedule.filter { $0.channelID == program.channelID && $0.start > program.start && $0.end > $0.start }
            .min { $0.start < $1.start }
    }
}

/// Transport streams can expose a discontinuous PCR timestamp while opening or
/// crossing an archive segment. Only continuous decoder time advances progress.
struct CatchupPlaybackClock {
    private(set) var position: Double
    private var sample: (time: Double, uptime: TimeInterval)?
    private let startedAt: TimeInterval
    init(position: Double, uptime: TimeInterval) {
        self.position = position; startedAt = uptime
    }
    mutating func update(time: Double, uptime: TimeInterval) -> Double {
        guard time.isFinite, time >= 0 else { return position }
        if let sample {
            let delta = time - sample.time
            if delta >= -0.25, delta <= max(2, uptime - sample.uptime + 1) {
                position = max(0, position + delta)
            }
        } else {
            guard time <= max(5, uptime - startedAt + 2) else { return position }
            position += time
        }
        sample = (time, uptime)
        return position
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
                guard name != nil else { continue }
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
                entry.tvgName = attributes["tvg-name"]
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

enum GuideDates {
    static func availableDays(in programs: [GuideProgram], now: Date = .now, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        guard let first = programs.lazy.map(\.start).min(), let last = programs.lazy.map(\.end).max() else { return [today] }
        var days = Set<Date>([today])
        var day = calendar.startOfDay(for: first)
        // An airing ending exactly at midnight belongs to the preceding day.
        let end = calendar.startOfDay(for: last.addingTimeInterval(-0.001))
        while day <= end {
            days.insert(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return days.sorted()
    }

    static func retainingCatchupHistory(_ previous: [GuideProgram], incoming: [GuideProgram], channels: [LiveChannel], now: Date = .now) -> [GuideProgram] {
        let windows = Dictionary(channels.compactMap { channel -> (String, Int)? in
            guard let guideID = channel.guideID, let days = channel.archiveDays, days > 0 else { return nil }
            return (guideID, days)
        }, uniquingKeysWith: max)
        var merged: [String: GuideProgram] = [:]
        for program in previous {
            guard let days = windows[program.channelID], program.end <= now,
                  program.start >= now.addingTimeInterval(-Double(days) * 86400) else { continue }
            merged[program.id] = program
        }
        // Fresh provider data wins, including corrected titles and times.
        for program in incoming { merged[program.id] = program }
        return merged.values.sorted { $0.start < $1.start }
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
    private var excludedChannelIDs: Set<String> = []
    private var attributes: [String: String] = [:]
    private var title = ""
    private var summary = ""
    private var element = ""
    private var inProgram = false

    static func parse(_ data: Data, excludingChannelIDs: Set<String> = []) throws -> [GuideProgram] {
        let delegate = XMLTVParser()
        delegate.excludedChannelIDs = excludingChannelIDs
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
            if let channel = attributes["channel"], !excludedChannelIDs.contains(channel), let start = Self.date(attributes["start"]), let end = Self.date(attributes["stop"]), end > start {
                programs.append(GuideProgram(channelID: channel, title: title, summary: summary, start: start, end: end))
            }
            inProgram = false
        }
        element = ""
    }
    private static let zonedDateFormatter: DateFormatter = makeFormatter("yyyyMMddHHmmss Z")
    private static let utcDateFormatter: DateFormatter = makeFormatter("yyyyMMddHHmmss")
    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value.contains(" ") ? zonedDateFormatter : utcDateFormatter).date(from: value)
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
    private static let cached = read()
    static func load() -> [LiveChannel] { cached }
    private static func read() -> [LiveChannel] {
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

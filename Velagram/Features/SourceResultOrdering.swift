import Foundation

enum SourceResultSort: String, CaseIterable, Identifiable {
    case date = "Message date", size = "File size", quality = "Quality", title = "File name", chat = "Chat / provider"
    var id: Self { self }
}
struct SourceResultInfo: Sendable {
    let id: String
    let title: String
    let origin: String
    let metadata: StreamDisplayMetadata?
    let date: Date?
    var additionalText: String = ""
    var searchable: String { [title, origin, additionalText, date?.formatted(date: .abbreviated, time: .omitted), metadata?.quality, metadata?.container, metadata?.releaseType].compactMap { $0 }.joined(separator: " ") }
    var qualityHeight: Int? {
        let text = (metadata?.quality ?? title).lowercased()
        if text.contains("8k") { return 4320 }; if text.contains("4k") { return 2160 }
        return [4320, 2160, 1440, 1080, 720, 576, 480, 360].first { text.contains(String($0)) }
    }
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { searchable.localizedStandardContains(String($0)) }
    }
    static func ordered(_ left: Self, _ right: Self, by sort: SourceResultSort, ascending: Bool) -> Bool {
        func compare<T: Comparable>(_ l: T?, _ r: T?) -> Bool? {
            // Unknown values stay last in both directions.
            if l == nil, r != nil { return false }; if l != nil, r == nil { return true }
            guard let l, let r, l != r else { return nil }
            return ascending ? l < r : l > r
        }
        let result: Bool?
        switch sort {
        case .date: result = compare(left.date, right.date)
        case .size: result = compare(left.metadata?.sizeBytes, right.metadata?.sizeBytes)
        case .quality: result = compare(left.qualityHeight, right.qualityHeight)
        case .title: result = compare(left.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), right.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        case .chat: result = compare(left.origin.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), right.origin.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
        return result ?? (left.id < right.id)
    }
}

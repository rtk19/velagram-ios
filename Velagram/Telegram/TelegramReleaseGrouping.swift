import Foundation

struct TelegramReleaseGroup: Identifiable, Sendable {
    let id: String
    let locations: [TelegramMedia]
    var representative: TelegramMedia { locations[0] }
    static func group(_ media: [TelegramMedia]) -> [Self] {
        // Match full release names (including codec/resolution) and exact byte
        // counts. Generic names must not collapse unrelated equal-size videos.
        var groups: [String: [TelegramMedia]] = [:]
        var uniqueKeys: [String: String] = [:]
        for item in media {
            let name = TelegramCatalogMatching.normalized(item.name)
            let base = TelegramCatalogMatching.normalized((item.name as NSString).deletingPathExtension)
            let generic = base.replacingOccurrences(of: #"[\d\s]+"#, with: "", options: .regularExpression).isEmpty || name.isEmpty || ["video mp4", "video mkv", "file mp4", "video", "media"].contains(name)
                || name.replacingOccurrences(of: #"[\d\s]+"#, with: "", options: .regularExpression).isEmpty
            let filenameKey = item.size > 0 && !generic ? "file:\(name):\(item.size)" : "message:\(item.id)"
            let key = item.remoteUniqueID.flatMap { uniqueKeys[$0] } ?? filenameKey
            if let unique = item.remoteUniqueID, !unique.isEmpty { uniqueKeys[unique] = key }
            if !(groups[key]?.contains(where: { $0.id == item.id }) ?? false) { groups[key, default: []].append(item) }
        }
        return groups.map { key, locations in
            Self(id: key, locations: locations.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date })
        }.sorted { $0.id < $1.id }
    }
}

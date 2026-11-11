import Foundation

/// Coordinates eviction with every app-owned media reader and offline download.
final class CacheUsage: @unchecked Sendable {
    static let shared = CacheUsage()
    private let lock = NSLock()
    private var readers = 0
    private var cleaning = false
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseBlock: (@Sendable () -> Void)?
        init(_ release: @escaping @Sendable () -> Void) { releaseBlock = release }
        func release() { let block = lock.withLock { let value = releaseBlock; releaseBlock = nil; return value }; block?() }
        deinit { release() }
    }
    func reader() throws -> Lease {
        try lock.withLock {
            guard !cleaning else { throw CacheManagementError.cleaning }
            readers += 1
            return Lease { [self] in lock.withLock { readers -= 1 } }
        }
    }
    func waitForReader() async throws -> Lease {
        while true {
            try Task.checkCancellation()
            if let lease = try? reader() { return lease }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func eviction() throws -> Lease {
        try lock.withLock {
            guard readers == 0 else { throw CacheManagementError.inUse }
            guard !cleaning else { throw CacheManagementError.cleaning }
            cleaning = true
            return Lease { [self] in lock.withLock { cleaning = false } }
        }
    }
}

enum CacheManagementError: LocalizedError {
    case inUse, cleaning, telegramUnavailable
    var errorDescription: String? {
        switch self {
        case .inUse: "Close the player, stop casting, and finish or cancel active downloads before clearing cache."
        case .cleaning: "Cache cleanup is in progress. Please try again shortly."
        case .telegramUnavailable: "Telegram cache could not be cleared. Connect your Telegram account and try again."
        }
    }
}

enum VideoCacheRetention: Int, CaseIterable, Identifiable {
    case oneDay = 1, threeDays = 3, oneWeek = 7, oneMonth = 30, forever = 0
    static let defaultsKey = "cache.video.retentionDays"
    var id: Int { rawValue }
    var title: String {
        switch self { case .oneDay: "1 day"; case .threeDays: "3 days"; case .oneWeek: "7 days"; case .oneMonth: "30 days"; case .forever: "Forever" }
    }
}

enum CacheCleanup: String, Identifiable {
    case videos, images, subtitles, all
    var id: String { rawValue }
    var title: String {
        switch self { case .videos: "Clear video cache"; case .images: "Clear artwork & thumbnails"; case .subtitles: "Clear subtitle cache"; case .all: "Clear all cache" }
    }
}

struct CacheOverview: Sendable {
    var video: Int64 = 0
    var images: Int64 = 0
    var subtitles: Int64 = 0
    var other: Int64 = 0
    var savedDownloads: Int64 = 0
    var available: Int64 = 0
    var telegramAvailable = false
    var total: Int64 { video + images + subtitles + other }
}

struct TelegramCacheStatistics: Sendable {
    static let videoTypes: Set<String> = ["fileTypeVideo", "fileTypeDocument", "fileTypeVideoNote"]
    static let imageTypes: Set<String> = ["fileTypePhoto", "fileTypeThumbnail", "fileTypeProfilePhoto", "fileTypeWallpaper", "fileTypeBackground"]
    var video: Int64 = 0
    var images: Int64 = 0
    var total: Int64 = 0
    var types: Set<String> = []
    init(_ json: TelegramJSON) {
        total = max(0, json["size"].int64 ?? 0)
        for chat in json["by_chat"].array {
            for entry in chat["by_file_type"].array {
                let type = entry["file_type"].type
                let size = max(0, entry["size"].int64 ?? 0)
                if type.hasPrefix("fileType") { types.insert(type) }
                if Self.videoTypes.contains(type) { video += size }
                else if Self.imageTypes.contains(type) { images += size }
            }
        }
    }
}

/// Only explicitly owned, rebuildable caches are enumerated/removed. Auth,
/// library/backup state, imported playlists and saved offline media are outside it.
actor CacheManager {
    static let shared = CacheManager()
    static let sizeLimitKey = "cache.video.limitGB"
    private let caches: URL
    private let support: URL
    private let temporary: URL
    private let defaults: UserDefaults
    private let subtitleCache: SubtitleRenditionCache?
    private let httpCache: URLCache
    private let usage: CacheUsage
    private let fm = FileManager.default
    private var lastMaintenance: Date?
    private var pendingMaintenance = false
    init(caches: URL? = nil, support: URL? = nil, temporary: URL? = nil, defaults: UserDefaults = .standard, usage: CacheUsage = .shared, subtitleCache: SubtitleRenditionCache? = .shared, httpCache: URLCache = .shared) {
        self.caches = caches ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.temporary = temporary ?? FileManager.default.temporaryDirectory
        self.defaults = defaults; self.usage = usage; self.subtitleCache = subtitleCache; self.httpCache = httpCache
    }
    func overview(transport: (any TelegramTransport)?) async -> CacheOverview {
        var result = CacheOverview()
        let telegramDisk = diskBytes(caches.appending(path: "VelagramTelegram"))
        result.video = telegramDisk
        if let transport, let json = try? await transport.call("getStorageStatistics", ["chat_limit": .integer(0)], timeout: 10), json.type == "storageStatistics" {
            let stats = TelegramCacheStatistics(json)
            result.telegramAvailable = true
            result.video = stats.video
            result.images = stats.images
            result.other = max(0, max(telegramDisk, stats.total) - stats.video - stats.images)
        }
        result.images += diskBytes(caches.appending(path: "TMDBImages"))
        result.subtitles = diskBytes(caches.appending(path: "Velagram/Subtitles"))
        result.other += diskBytes(support.appending(path: "Velagram/PlaybackDiagnostics")) + temporaryFiles().reduce(0) { $0 + diskBytes($1) }
        result.other += Int64(httpCache.currentDiskUsage)
        result.savedDownloads = max(0, diskBytes(support.appending(path: "Velagram/TelegramDownloads")) - diskBytes(support.appending(path: "Velagram/TelegramDownloads/downloads.json")))
        result.available = (try? fm.attributesOfFileSystem(forPath: caches.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return result
    }
    func clear(_ action: CacheCleanup, transport: (any TelegramTransport)?) async throws {
        let lease = try usage.eviction(); defer { lease.release() }
        // Never unlink TDLib files behind its database: native eviction keeps
        // getFile/downloaded-prefix metadata consistent with the disk.
        if action != .subtitles {
            if let transport {
                let json = try await transport.call("getStorageStatistics", ["chat_limit": .integer(0)], timeout: 15)
                guard json.type == "storageStatistics" else { throw CacheManagementError.telegramUnavailable }
                let stats = TelegramCacheStatistics(json)
                let selected = action == .videos ? stats.types.intersection(TelegramCacheStatistics.videoTypes) : action == .images ? stats.types.intersection(TelegramCacheStatistics.imageTypes) : stats.types
                if !selected.isEmpty { _ = try await transport.call("optimizeStorage", Self.optimization(types: selected, days: 0, limit: 0), timeout: 90) }
            } else if diskBytes(caches.appending(path: "VelagramTelegram")) > 0 {
                throw CacheManagementError.telegramUnavailable
            }
        }
        if action == .images || action == .all { try remove(caches.appending(path: "TMDBImages")) }
        if action == .subtitles || action == .all {
            await subtitleCache?.removeAll()
            try remove(caches.appending(path: "Velagram/Subtitles"))
        }
        if action == .all {
            httpCache.removeAllCachedResponses()
            try remove(support.appending(path: "Velagram/PlaybackDiagnostics"))
            for file in temporaryFiles() { try remove(file) }
        }
        defaults.set(Date().timeIntervalSince1970, forKey: "cache.lastCleaned")
    }
    func maintain(transport: any TelegramTransport, force: Bool = false, now: Date = .now) async {
        if force { pendingMaintenance = true }
        guard pendingMaintenance || (lastMaintenance.map({ now.timeIntervalSince($0) > 6 * 3600 }) ?? true) else { return }
        let days = VideoCacheRetention(rawValue: defaults.object(forKey: VideoCacheRetention.defaultsKey) as? Int ?? 7) ?? .oneWeek
        let gb = defaults.integer(forKey: Self.sizeLimitKey)
        guard days != .forever || gb > 0 else { pendingMaintenance = false; return }
        guard let lease = try? usage.eviction() else { return }
        defer { lease.release() }
        do {
            _ = try await transport.call("optimizeStorage", Self.optimization(types: TelegramCacheStatistics.videoTypes, days: days == .forever ? nil : days.rawValue, limit: gb > 0 ? Int64(gb) * 1_000_000_000 : nil), timeout: 60)
            lastMaintenance = now; pendingMaintenance = false
        } catch { /* Retry on the next idle foreground; no destructive fallback. */ }
    }
    nonisolated static func optimization(types: Set<String>, days: Int?, limit: Int64?) -> [String: TelegramJSON] {
        ["size": .integer(limit ?? 9_007_199_254_740_991), "ttl": .integer(days.map { Int64($0) * 86400 } ?? Int64(Int32.max)),
         "count": .integer(Int64(Int32.max)), "immunity_delay": .integer(0),
         "file_types": .array(types.sorted().map { .request($0) }), "chat_ids": .array([]), "exclude_chat_ids": .array([]),
         "return_deleted_file_statistics": .bool(false), "chat_limit": .integer(0)]
    }
    private func remove(_ url: URL) throws { if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) } }
    private func temporaryFiles() -> [URL] {
        ((try? fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []).filter {
            $0.lastPathComponent.hasPrefix("Velagram-HLS-") || $0.lastPathComponent.hasPrefix("PlayerPreview.") || ["vtt", "srt", "ass", "ssa"].contains($0.pathExtension.lowercased())
        }
    }
    /// Allocated bytes, not logical file size: TDLib caches can be sparse files.
    private func diskBytes(_ root: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return 0 }
        if let values = try? root.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants]) else { return 0 }
        var result: Int64 = 0
        for case let url as URL in iterator {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values.isRegularFile == true { result += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0) }
        }
        return result
    }
}

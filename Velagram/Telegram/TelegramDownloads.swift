import Foundation
import Observation
import Network
import AVFoundation

struct TelegramSavedDownload: Identifiable, Codable, Hashable, Sendable {
    var id: String { media.id }
    let media: TelegramMedia
    let filename: String
    let savedAt: Date
    var catalogMedia: MediaItem? = nil
    var catalogEpisode: MediaEpisode? = nil
    var cachedPath: String? = nil
    var sourceID: String? = nil
    var offlineAssetPath: String? = nil
    var artworkFilename: String? = nil
    var rowArtworkFilename: String? = nil
    var titleArtworkFilename: String? = nil
    var isCached: Bool { cachedPath != nil }
    var request: PlaybackRequest? { catalogMedia.map { PlaybackRequest(media: $0, episode: catalogEpisode) } }
    var url: URL {
        if let offlineAssetPath {
            return (offlineAssetPath as NSString).isAbsolutePath
                ? URL(fileURLWithPath: offlineAssetPath)
                : URL(fileURLWithPath: NSHomeDirectory()).appending(path: offlineAssetPath)
        }
        return cachedPath.map { URL(fileURLWithPath: $0) } ?? Self.directory.appending(path: filename) }
    var artworkURL: URL? { artworkFilename.map { Self.directory.appending(path: $0) } }
    var titleArtworkURL: URL? { titleArtworkFilename.map { Self.directory.appending(path: $0) } }
    var rowArtworkURL: URL? { rowArtworkFilename.map { Self.directory.appending(path: $0) } ?? artworkURL }
    var artworkFilenames: Set<String> { Set([artworkFilename, rowArtworkFilename, titleArtworkFilename].compactMap { $0 }) }
    func matches(_ request: PlaybackRequest) -> Bool {
        guard let media = catalogMedia, media.artworkIdentityKey == request.media.artworkIdentityKey else { return false }
        return catalogEpisode?.seasonNumber == request.episode?.seasonNumber && catalogEpisode?.number == request.episode?.number
    }
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Velagram/TelegramDownloads") }
}

/// Transfer measurements are independent of playback/resume progress.
struct DownloadTransferProgress: Equatable, Sendable {
    var received: Int64
    var total: Int64
    var bytesPerSecond: Double
    var sampledAt: TimeInterval
    var mediaFraction: Double? = nil
    var fraction: Double? { mediaFraction ?? (total > 0 ? min(1, Double(max(0, received)) / Double(total)) : nil) }
    var percentage: String { fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "—" }
    var sizeLabel: String {
        if mediaFraction != nil { return "Saving video for offline playback" }
        let size = ByteCountFormatter.string(fromByteCount: max(0, received), countStyle: .file)
        return total > 0 ? size + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : size + " downloaded"
    }
    func speedLabel(now: TimeInterval) -> String {
        if mediaFraction != nil { return "Video download" }
        let speed = now - sampledAt > 3 ? 0 : max(0, bytesPerSecond)
        guard speed >= 1 else { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(speed, Double(Int64.max / 2))), countStyle: .file) + "/s"
    }
    static func combined(_ values: [Self], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Self? {
        guard !values.isEmpty else { return nil }
        return Self(received: values.reduce(0) { $0 + $1.received },
                    total: values.allSatisfy { $0.total > 0 } ? values.reduce(0) { $0 + $1.total } : 0,
                    bytesPerSecond: values.reduce(0) { $0 + (now - $1.sampledAt <= 3 ? $1.bytesPerSecond : 0) }, sampledAt: values.map(\.sampledAt).max() ?? 0)
    }
}

/// A source is a release, not an individual Telegram message location.
struct OfflineLibrarySource: Identifiable {
    let id: String
    let media: TelegramMedia
    let request: PlaybackRequest?
    let record: TelegramSavedDownload?
    let transferID: String?
    let provider: String
    var titleKey: String {
        if let request { return request.media.providerID == "offline" ? request.media.id : request.media.artworkIdentityKey }
        return "local:" + media.seriesKey
    }
    var contentKey: String {
        let season = request?.episode?.seasonNumber ?? media.episode?.season
        let episode = request?.episode?.number ?? media.episode?.episode
        return season.map { "s\($0)e\(episode ?? 0)" } ?? "movie"
    }
}
struct OfflineLibraryContent: Identifiable {
    let id: String
    let request: PlaybackRequest
    let sources: [OfflineLibrarySource]
    var artworkURL: URL? { sources.compactMap { $0.record?.rowArtworkURL }.first }
    @MainActor func progress(in library: LibraryStore) -> WatchProgress {
        library.progress(for: request) ?? WatchProgress(contentID: request.contentID, providerID: request.media.providerID,
            media: request.media, episode: request.episode, position: 0,
            duration: Double(sources.map { $0.media.duration }.max() ?? 0), updatedAt: .distantPast)
    }
}
struct OfflineLibraryTitle: Identifiable {
    let id: String
    let media: MediaItem
    let contents: [OfflineLibraryContent]
    var availableContents: [OfflineLibraryContent] { contents.filter { $0.sources.contains { $0.record != nil } } }
    var activeContents: [OfflineLibraryContent] { contents.filter { $0.sources.contains { $0.transferID != nil } } }
    var availabilityLabel: String {
        let count = availableContents.count
        guard count > 0 else { return activeContents.isEmpty ? "Partially downloaded" : "Preparing offline viewing" }
        if media.kind == .movie {
            let sources = availableContents.reduce(0) { $0 + $1.sources.filter { $0.record != nil }.count }
            return "Available offline · \(sources) " + (sources == 1 ? "source" : "sources")
        }
        return "\(count) " + (count == 1 ? "episode" : "episodes")
    }

}
enum OfflineLibraryIndex {
    /// Prefer a permanent saved copy while retaining richer metadata/artwork
    /// from an equivalent cache entry. Different releases remain separate.
    static func unique(_ records: [TelegramSavedDownload]) -> [TelegramSavedDownload] {
        let telegram = records.filter { $0.media.chatID != 0 }
        var keys: [String: String] = [:]
        for group in TelegramReleaseGroup.group(telegram.map(\.media)) {
            for media in group.locations { keys[media.id] = group.id }
        }
        let groups = Dictionary(grouping: records) { record in
            record.media.chatID == 0 ? "web:" + (record.sourceID ?? record.id) : (keys[record.id] ?? record.id)
        }
        return groups.values.flatMap { group -> [TelegramSavedDownload] in
            func contentKey(_ record: TelegramSavedDownload) -> String? {
                guard let request = record.request else { return nil }
                return request.media.artworkIdentityKey + ":" + (request.episode.map { "\($0.seasonNumber):\($0.number)" } ?? "movie")
            }
            let known = Set(group.compactMap(contentKey))
            let contents = Dictionary(grouping: group) { record in contentKey(record) ?? (known.count == 1 ? known.first! : "raw:" + record.media.seriesKey + ":" + (record.media.episode.map { "\($0.season):\($0.episode)" } ?? "movie")) }
            return contents.values.map { copies in
                let ordered = copies.sorted {
                    if $0.isCached != $1.isCached { return !$0.isCached }
                    if ($0.catalogMedia != nil) != ($1.catalogMedia != nil) { return $0.catalogMedia != nil }
                    return $0.savedAt == $1.savedAt ? $0.id < $1.id : $0.savedAt > $1.savedAt
                }
                var preferred = ordered[0]
                if preferred.catalogMedia == nil, let metadata = ordered.first(where: { $0.catalogMedia != nil }) {
                    preferred.catalogMedia = metadata.catalogMedia; preferred.catalogEpisode = metadata.catalogEpisode
                }
                if preferred.artworkFilename == nil { preferred.artworkFilename = ordered.compactMap(\.artworkFilename).first }
                if preferred.titleArtworkFilename == nil { preferred.titleArtworkFilename = ordered.compactMap(\.titleArtworkFilename).first }
                if preferred.rowArtworkFilename == nil { preferred.rowArtworkFilename = ordered.compactMap(\.rowArtworkFilename).first }
                return preferred
            }
        }.sorted { $0.savedAt > $1.savedAt }
    }
    static func sameRelease(_ lhs: TelegramMedia, _ rhs: TelegramMedia) -> Bool {
        if lhs.id == rhs.id { return true }
        guard lhs.chatID != 0, rhs.chatID != 0 else { return false }
        return TelegramReleaseGroup.group([lhs, rhs]).count == 1
    }
    static func titles(_ sources: [OfflineLibrarySource]) -> [OfflineLibraryTitle] {
        var canonical: [String: Set<String>] = [:]
        for source in sources {
            guard let media = source.request?.media else { continue }
            for title in [media.title, media.originalTitle].compactMap({ $0 }) {
                canonical[TelegramCatalogMatching.normalized(title), default: []].insert(source.titleKey)
            }
        }
        return Dictionary(grouping: sources) { source in
            if source.request != nil { return source.titleKey }
            let matches = canonical[TelegramCatalogMatching.normalized(source.media.title)] ?? []
            return matches.count == 1 ? matches.first! : source.titleKey
        }.map { key, titleSources in
            let first = titleSources.first(where: { $0.request != nil }) ?? titleSources[0]
            let media = first.request?.media ?? MediaItem(id: key, providerID: "offline", kind: first.media.episode == nil ? .movie : .series, title: first.media.title)
            let contents = Dictionary(grouping: titleSources, by: \.contentKey).map { contentKey, values in
                let source = values.first(where: { $0.request != nil }) ?? values[0]
                let episode = source.request?.episode ?? source.media.episode.map {
                    MediaEpisode(id: key + ":" + contentKey, providerID: media.providerID, showID: media.id, seasonNumber: $0.season, number: $0.episode, title: nil, overview: nil, posterURL: nil)
                }
                return OfflineLibraryContent(id: key + ":" + contentKey, request: PlaybackRequest(media: media, episode: episode), sources: values.sorted { $0.id < $1.id })
            }.sorted { ($0.request.episode?.seasonNumber ?? 0, $0.request.episode?.number ?? 0) < ($1.request.episode?.seasonNumber ?? 0, $1.request.episode?.number ?? 0) }
            return OfflineLibraryTitle(id: key, media: media, contents: contents)
        }.sorted { $0.media.title.localizedStandardCompare($1.media.title) == .orderedAscending }
    }
}

@MainActor @Observable final class TelegramDownloads {
    static let shared = TelegramDownloads()
    var saved: [TelegramSavedDownload] = []
    var active: [Int: TelegramMedia] = [:]
    var errors: [Int: String] = [:]
    var webActive: Set<String> = []
    var webErrors: [String: String] = [:]
    var webProgress: [String: Double] = [:]
    var webTitles: [String: String] = [:]
    var webRequests: [String: PlaybackRequest] = [:]
    var webProviders: [String: String] = [:]
    var partialFiles: [Int: TelegramFile] = [:]
    var transferProgress: [String: DownloadTransferProgress] = [:]
    private var transferSamples: [String: (bytes: Int64, time: TimeInterval)] = [:]
    private var rawTracked: [Int: TelegramMedia] = [:]
    private var tracked: [Int: (TelegramMedia, PlaybackRequest)] = [:]
    private var webTasks: [String: Task<Void, Never>] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var cancelling: Set<Int> = []
    private var deleting: Set<Int> = []
    private var playbackOwners: [Int: Set<UUID>] = [:]
    private var fileOperations: [Int: (UUID, Task<Void, Error>)] = [:]
    private var manifest: URL { TelegramSavedDownload.directory.appending(path: "downloads.json") }
    private struct Association: Codable {
        let media: TelegramMedia
        let title: MediaItem?
        let episode: MediaEpisode?
    }
    private var associationsURL: URL { TelegramSavedDownload.directory.appending(path: "metadata.json") }
    init() {
        reload()
        if let data = try? Data(contentsOf: associationsURL), let values = try? JSONDecoder().decode([Association].self, from: data) {
            for value in values {
                if let id = value.media.fileID {
                    if let title = value.title { tracked[id] = (value.media, PlaybackRequest(media: title, episode: value.episode)) }
                    else { rawTracked[id] = value.media }
                }
            }
        }
    }
    func reload() {
        if let data = try? Data(contentsOf: manifest), let records = try? JSONDecoder().decode([TelegramSavedDownload].self, from: data) {
            saved = records
            discardMissingRecords()
            if saved.count != records.count { try? persist() }
        } else { saved = [] }
    }
    /// Index files watched before the unified library existed, using TDLib's
    /// local file database rather than starting a network download.
    func refreshCached(store: TelegramStore) async {
        var knownMedia = rawTracked
        for (id, value) in tracked { knownMedia[id] = value.0 }
        for media in store.recentMedia {
            if let id = media.fileID, knownMedia[id] == nil { knownMedia[id] = media }
        }
        for media in store.ready ? Array(knownMedia.values) : [] {
            guard !Task.isCancelled else { return }
            guard let id = media.fileID else { continue }
            if tracked[id] == nil { rawTracked[id] = media }
            if let response = try? await store.transport.call("getFile", ["file_id": .integer(Int64(id))], timeout: 5), let file = TelegramFile(response) {
                store.files[id] = file; completed(file)
            }
        }
        do { try persistAssociations() } catch { webErrors["metadata"] = error.localizedDescription }
        if !OfflineConnectivity.shared.isOffline {
            for record in OfflineLibraryIndex.unique(saved) where record.rowArtworkFilename == nil || (record.titleArtworkFilename == nil && record.catalogMedia?.backdropURL != nil) {
                guard !Task.isCancelled else { return }
                if let request = record.request { await saveArtwork(mediaID: record.id, request: request) }
            }
        }
    }
    private func matches(_ stored: PlaybackRequest, _ request: PlaybackRequest) -> Bool {
        stored.media.artworkIdentityKey == request.media.artworkIdentityKey &&
        stored.episode?.seasonNumber == request.episode?.seasonNumber && stored.episode?.number == request.episode?.number
    }
    /// Local metadata is available before the network scanner finds these messages again.
    func knownTelegram(for request: PlaybackRequest, store: TelegramStore) -> [TelegramMedia] {
        tracked.values.compactMap { media, stored in
            guard matches(stored, request), let id = media.fileID,
                  (store.files[id] ?? partialFiles[id])?.downloadedSize ?? 0 > 0 else { return nil }
            return media
        }
    }
    func refreshKnownFiles(for request: PlaybackRequest, store: TelegramStore) async {
        guard store.ready else { return }
        let media = tracked.values.filter { matches($0.1, request) }.map { $0.0 }
        for item in media {
            guard !Task.isCancelled else { return }
            guard let id = item.fileID else { continue }
            if let file = store.files[id] { completed(file); continue }
            if let response = try? await store.transport.call("getFile", ["file_id": .integer(Int64(id))], timeout: 5), let file = TelegramFile(response) {
                guard !Task.isCancelled else { return }
                if store.files[id] == nil { store.files[id] = file }
                completed(store.files[id] ?? file)
            }
        }
    }
    func local(_ media: TelegramMedia) -> URL? {
        OfflineLibraryIndex.unique(saved.filter { OfflineLibraryIndex.sameRelease($0.media, media) && FileManager.default.fileExists(atPath: $0.url.path) }).sorted { !$0.isCached && $1.isCached }.first?.url
    }
    func sources() -> [OfflineLibrarySource] {
        var result = OfflineLibraryIndex.unique(saved).map { record in
            let task = active.values.first { OfflineLibraryIndex.sameRelease($0, record.media) }
            return OfflineLibrarySource(id: "local:" + record.id, media: record.media, request: record.request, record: record,
                transferID: task?.fileID.map { "telegram:\($0)" }, provider: record.media.chatID == 0 ? record.media.caption : "Telegram")
        }
        for (id, media) in active where !result.contains(where: { OfflineLibraryIndex.sameRelease($0.media, media) }) {
            result.append(OfflineLibrarySource(id: "telegram:\(id)", media: media, request: tracked[id]?.1, record: nil, transferID: "telegram:\(id)", provider: "Telegram"))
        }
        for id in webActive {
            guard let request = webRequests[id], !result.contains(where: { $0.record?.sourceID == id && $0.record?.matches(request) == true }) else { continue }
            let media = TelegramMedia(chatID: 0, messageID: 0, fileID: nil, name: webTitles[id] ?? request.displayTitle, caption: "", date: .now, size: transferProgress["web:" + id]?.total ?? 0, duration: 0, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: nil)
            result.append(OfflineLibrarySource(id: "web:" + id, media: media, request: request, record: nil, transferID: "web:" + id, provider: webProviders[id] ?? "Web"))
        }
        for (id, file) in partialFiles.sorted(by: { $0.value.downloadedSize > $1.value.downloadedSize }) where active[id] == nil {
            guard let media = tracked[id]?.0 ?? rawTracked[id],
                  !result.contains(where: { OfflineLibraryIndex.sameRelease($0.media, media) }), file.downloadedSize > 0 else { continue }
            result.append(OfflineLibrarySource(id: "partial:\(id)", media: media, request: tracked[id]?.1, record: nil, transferID: nil, provider: "Telegram"))
        }
        return result
    }
    /// Serialize starts and stops so a delayed player shutdown cannot cancel a new download.
    private func fileOperation(_ id: Int, _ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = fileOperations[id]?.1
        let token = UUID()
        let task = Task { @MainActor in
            if let previous { _ = await previous.result }
            try await operation()
        }
        fileOperations[id] = (token, task)
        defer { if fileOperations[id]?.0 == token { fileOperations[id] = nil } }
        try await task.value
    }
    func requestPlaybackRange(transport: any TelegramTransport, fileID: Int, offset: Int64, limit: Int64, priority: Int64, owner: TelegramPlaybackDownloadOwner? = nil) async throws {
        try Task.checkCancellation()
        if let owner {
            guard !owner.isClosed else { throw CancellationError() }
            playbackOwners[fileID, default: []].insert(owner.id)
        }
        try await fileOperation(fileID) { [self] in
            guard owner?.isClosed != true else { throw CancellationError() }
            guard active[fileID] == nil else { return }
            guard !deleting.contains(fileID), !cancelling.contains(fileID) else { throw CancellationError() }
            _ = try await transport.call("downloadFile", ["file_id": .integer(Int64(fileID)), "priority": .integer(priority), "offset": .integer(offset), "limit": .integer(limit), "synchronous": .bool(false)])
        }
    }
    func endPlayback(transport: any TelegramTransport, fileID: Int, owner: TelegramPlaybackDownloadOwner) async {
        owner.close()
        guard playbackOwners[fileID]?.remove(owner.id) != nil else { return }
        if playbackOwners[fileID]?.isEmpty == true { playbackOwners[fileID] = nil }
        try? await fileOperation(fileID) { [self] in
            guard playbackOwners[fileID] == nil, active[fileID] == nil else { return }
            _ = try await transport.call("cancelDownloadFile", ["file_id": .integer(Int64(fileID)), "only_if_pending": .bool(false)])
        }
    }
    func startOfflineTransfer(transport: any TelegramTransport, fileID: Int) async throws {
        try Task.checkCancellation()
        try await fileOperation(fileID) { [self] in
            guard active[fileID] != nil, !deleting.contains(fileID), !cancelling.contains(fileID) else { throw CancellationError() }
            _ = try await transport.call("downloadFile", ["file_id": .integer(Int64(fileID)), "priority": .integer(8), "offset": .integer(0), "limit": .integer(0), "synchronous": .bool(false)])
        }
    }
    func deleteSource(_ media: TelegramMedia, store: TelegramStore) async throws {
        let copies = saved.filter { OfflineLibraryIndex.sameRelease($0.media, media) }
        let ids = Set(([media] + copies.map(\.media) + Array(rawTracked.values) + tracked.values.map { $0.0 }).filter { OfflineLibraryIndex.sameRelease($0, media) }.compactMap(\.fileID))
        guard deleting.isDisjoint(with: ids) else { return }
        deleting.formUnion(ids); defer { deleting.subtract(ids) }
        let pending = ids.compactMap { tasks[$0] }
        for id in ids { tasks[id]?.cancel() }
        for task in pending { await task.value }
        let lease = try CacheUsage.shared.eviction(); defer { lease.release() }
        for id in ids {
            _ = try await store.transport.call("cancelDownloadFile", ["file_id": .integer(Int64(id)), "only_if_pending": .bool(false)])
            _ = try await store.transport.call("deleteFile", ["file_id": .integer(Int64(id))])
            store.files[id] = nil; partialFiles[id] = nil; tracked[id] = nil; rawTracked[id] = nil
        }
        for copy in copies where !copy.isCached && FileManager.default.fileExists(atPath: copy.url.path) { try FileManager.default.removeItem(at: copy.url) }
        saved.removeAll { OfflineLibraryIndex.sameRelease($0.media, media) }
        cleanupArtwork(copies); try persist(); try persistAssociations()
    }
    func updateProgress(_ key: String, received: Int64, total: Int64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let previous = transferProgress[key]
        let received = max(received, previous?.received ?? 0)
        var speed = previous?.bytesPerSecond ?? 0
        if let sample = transferSamples[key], now - sample.time >= 0.25 {
            let measured = Double(max(0, received - sample.bytes)) / (now - sample.time)
            speed = speed > 0 ? speed * 0.5 + measured * 0.5 : measured
            transferSamples[key] = (received, now)
        } else if transferSamples[key] == nil { transferSamples[key] = (received, now) }
        transferProgress[key] = DownloadTransferProgress(received: max(0, received), total: max(0, total), bytesPerSecond: speed, sampledAt: now)
    }
    func updateProgress(_ file: TelegramFile) {
        guard active[file.id] != nil else { return }
        updateProgress("telegram:\(file.id)", received: file.downloadedSize, total: file.size)
    }
    private func finishProgress(_ key: String) { transferProgress[key] = nil; transferSamples[key] = nil }
    func cancelTransfer(_ key: String, store: TelegramStore) {
        if key.hasPrefix("telegram:"), let id = Int(key.dropFirst(9)) { cancel(id, store: store) }
        else if key.hasPrefix("web:") { cancelWeb(String(key.dropFirst(4))) }
    }
    func reconcileEpisodes(_ episodes: [MediaEpisode], in show: MediaItem) {
        var changed = false
        for index in saved.indices {
            guard saved[index].catalogMedia?.artworkIdentityKey == show.artworkIdentityKey,
                  let old = saved[index].catalogEpisode,
                  let episode = episodes.first(where: {
                      $0.seasonNumber == old.seasonNumber && $0.number == old.number
                  }), old != episode else { continue }
            saved[index].catalogMedia = show
            saved[index].catalogEpisode = episode
            let mediaID = saved[index].id
            Task { await saveArtwork(mediaID: mediaID, request: PlaybackRequest(media: show, episode: episode), refreshLandscape: old.posterURL != episode.posterURL) }
            changed = true
        }
        if changed { try? persist() }
    }

    func available(for request: PlaybackRequest) -> [TelegramSavedDownload] {
        OfflineLibraryIndex.unique(saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }).filter { $0.matches(request) }.sorted { !$0.isCached && $1.isCached }
    }
    func track(_ media: TelegramMedia, request: PlaybackRequest, store: TelegramStore) {
        guard let id = media.fileID else { return }
        let changed = tracked[id]?.0 != media || tracked[id]?.1 != request
        tracked[id] = (media, request)
        if changed {
            do {
                try FileManager.default.createDirectory(at: TelegramSavedDownload.directory, withIntermediateDirectories: true)
                try persistAssociations()
            } catch { errors[id] = "Could not save offline metadata: " + error.localizedDescription }
        }
        for index in saved.indices where OfflineLibraryIndex.sameRelease(saved[index].media, media) {
            saved[index].catalogMedia = request.media; saved[index].catalogEpisode = request.episode
        }
        if saved.contains(where: { OfflineLibraryIndex.sameRelease($0.media, media) }) { try? persist() }
        if let file = store.files[id] { completed(file) }
    }
    func trackRaw(_ media: TelegramMedia, store: TelegramStore) {
        guard let id = media.fileID else { return }
        rawTracked[id] = media
        do { try persistAssociations() } catch { errors[id] = error.localizedDescription }
        if let file = store.files[id] { completed(file) }
    }
    private func persistAssociations() throws {
        try FileManager.default.createDirectory(at: TelegramSavedDownload.directory, withIntermediateDirectories: true)
        let values = tracked.values.map { Association(media: $0.0, title: $0.1.media, episode: $0.1.episode) } +
            rawTracked.filter { tracked[$0.key] == nil }.values.map { Association(media: $0, title: nil, episode: nil) }
        try JSONEncoder().encode(values).write(to: associationsURL, options: .atomic)
    }
    func completed(_ snapshot: TelegramFile) {
        var file = snapshot
        if file.downloadedSize > 0, let previous = partialFiles[file.id], previous.localPath == file.localPath {
            file.downloadedSize = max(file.downloadedSize, previous.downloadedSize)
        }
        if !file.completed, file.downloadedSize > 0 { partialFiles[file.id] = file } else { partialFiles[file.id] = nil }
        updateProgress(file)
        guard file.completed, !file.localPath.isEmpty, let media = tracked[file.id]?.0 ?? rawTracked[file.id],
              !saved.contains(where: { OfflineLibraryIndex.sameRelease($0.media, media) }), FileManager.default.fileExists(atPath: file.localPath) else { return }
        let request = tracked[file.id]?.1
        let record = TelegramSavedDownload(media: media, filename: "", savedAt: .now, catalogMedia: request?.media, catalogEpisode: request?.episode, cachedPath: file.localPath)
        saved.insert(record, at: 0)
        do { try persist() } catch { errors[file.id] = error.localizedDescription }
        if let request { Task { await saveArtwork(mediaID: media.id, request: request) } }
    }
    func saveArtwork(mediaID: String, request: PlaybackRequest, refreshLandscape: Bool = false) async {
        let poster = request.media.posterURL ?? request.episode?.posterURL
        let landscape = request.episode?.posterURL ?? request.media.backdropURL ?? poster
        for (url, kind) in [(poster, 0), (landscape == poster ? nil : landscape, 1), (request.media.backdropURL, 2)] {
            guard let url, !Task.isCancelled else { continue }
            guard let current = saved.first(where: { $0.id == mediaID }) else { return }
            if [current.artworkFilename, current.rowArtworkFilename, current.titleArtworkFilename][kind] != nil,
               !(kind == 1 && refreshLandscape) { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let filename = UUID().uuidString + ".jpg"
                try data.write(to: TelegramSavedDownload.directory.appending(path: filename), options: .atomic)
                guard let index = saved.firstIndex(where: { $0.id == mediaID }) else {
                    try? FileManager.default.removeItem(at: TelegramSavedDownload.directory.appending(path: filename)); return
                }
                let previousLandscape = saved[index].rowArtworkFilename
                switch kind {
                case 1: saved[index].rowArtworkFilename = filename
                case 2: saved[index].titleArtworkFilename = filename
                default: saved[index].artworkFilename = filename
                }
                try persist()
                if kind == 1, let previousLandscape,
                   !saved.contains(where: { $0.artworkFilenames.contains(previousLandscape) }) {
                    try? FileManager.default.removeItem(at: TelegramSavedDownload.directory.appending(path: previousLandscape))
                }
            } catch { /* Local metadata and video stay usable with existing artwork. */ }
        }
    }
    func begin(_ candidate: PlaybackCandidate, request: PlaybackRequest) {
        guard !webActive.contains(candidate.id), !saved.contains(where: { $0.sourceID == candidate.id && $0.matches(request) }) else { return }
        webActive.insert(candidate.id); webErrors[candidate.id] = nil; webProgress[candidate.id] = nil; webTitles[candidate.id] = candidate.preference.serverName
        webRequests[candidate.id] = request; webProviders[candidate.id] = candidate.providerName
        updateProgress("web:" + candidate.id, received: 0, total: candidate.displayMetadata?.sizeBytes ?? 0)
        webTasks[candidate.id] = Task { [self] in
            defer { webActive.remove(candidate.id); webTasks[candidate.id] = nil; webProgress[candidate.id] = nil; webTitles[candidate.id] = nil; webRequests[candidate.id] = nil; webProviders[candidate.id] = nil; finishProgress("web:" + candidate.id) }
            do {
                let lease = try await CacheUsage.shared.waitForReader(); defer { lease.release() }
                let source = try await candidate.resolve()
                if ["m3u8", "m3u"].contains(source.url.pathExtension.lowercased()) {
                    try await saveHLS(source, candidate: candidate, request: request)
                    return
                }
                if source.url.pathExtension.lowercased() == "mpd" {
                    throw TelegramError(code: -1, message: "This source uses DASH, which iOS cannot save for offline playback. Try another source for this title.")
                }
                var downloadRequest = URLRequest(url: source.url)
                source.headers.forEach { downloadRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
                transferSamples["web:" + candidate.id] = (0, ProcessInfo.processInfo.systemUptime)
                let progress = OfflineDownloadProgress { [weak self] received, expected in
                    Task { @MainActor [weak self] in
                        guard self?.webActive.contains(candidate.id) == true else { return }
                        self?.webProgress[candidate.id] = expected > 0 ? min(1, Double(received) / Double(expected)) : nil
                        self?.updateProgress("web:" + candidate.id, received: received, total: expected)
                    }
                }
                let (temporary, response) = try await URLSession.shared.download(for: downloadRequest, delegate: progress)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppError.noStream }
                let mime = (http.mimeType ?? "").lowercased()
                if mime.contains("mpegurl") {
                    try? FileManager.default.removeItem(at: temporary)
                    try await saveHLS(source, candidate: candidate, request: request)
                    return
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                let supported = ["mp4", "mkv", "mov", "m4v", "webm", "avi", "ts"]
                let suggestedExtension = (response.suggestedFilename as NSString?)?.pathExtension.lowercased() ?? ""
                let ext = supported.contains(suggestedExtension) ? suggestedExtension : source.url.pathExtension.lowercased()
                guard !mime.contains("mpegurl"), !mime.contains("dash"),
                      mime.hasPrefix("video/") || mime == "application/octet-stream" || mime == "application/x-matroska" || (mime.isEmpty && supported.contains(ext)) else {
                    throw TelegramError(code: -1, message: "This source is not a downloadable video file. Choose a file source for offline viewing.")
                }
                let bytes = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
                guard let bytes, bytes.int64Value > 0,
                      response.expectedContentLength <= 0 || bytes.int64Value == response.expectedContentLength else { throw AppError.noStream }
                try Task.checkCancellation()
                let mimeExtensions = ["video/x-matroska": "mkv", "application/x-matroska": "mkv", "video/webm": "webm", "video/mp2t": "ts", "video/quicktime": "mov", "video/x-msvideo": "avi"]
                let fileExtension = supported.contains(ext) ? ext : (mimeExtensions[mime] ?? "mp4")
                let filename = UUID().uuidString + "." + fileExtension
                try FileManager.default.createDirectory(at: TelegramSavedDownload.directory, withIntermediateDirectories: true)
                let destination = TelegramSavedDownload.directory.appending(path: filename)
                try FileManager.default.moveItem(at: temporary, to: destination)
                let media = TelegramMedia(chatID: 0, messageID: Int64.random(in: 1...Int64.max), fileID: nil, name: request.displayTitle + "." + fileExtension, caption: candidate.providerName, date: .now, size: bytes.int64Value, duration: 0, mimeType: http.mimeType ?? "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: nil)
                saved.insert(TelegramSavedDownload(media: media, filename: filename, savedAt: .now, catalogMedia: request.media, catalogEpisode: request.episode, sourceID: candidate.id), at: 0)
                do { try persist() } catch {
                    saved.removeAll { $0.id == media.id }; try? FileManager.default.removeItem(at: destination); throw error
                }
                await saveArtwork(mediaID: media.id, request: request)
            } catch { if !Task.isCancelled { webErrors[candidate.id] = error.localizedDescription } }
        }
    }
    private func saveHLS(_ source: PlaybackSource, candidate: PlaybackCandidate, request: PlaybackRequest) async throws {
        let downloader = OfflineHLSDownload()
        let location = try await downloader.download(source: source, title: request.displayTitle) { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.webActive.contains(candidate.id) else { return }
                self.transferProgress["web:" + candidate.id] = DownloadTransferProgress(
                    received: 0, total: 0, bytesPerSecond: 0, sampledAt: ProcessInfo.processInfo.systemUptime,
                    mediaFraction: max(fraction, self.transferProgress["web:" + candidate.id]?.mediaFraction ?? 0))
            }
        }
        do {
            try Task.checkCancellation()
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
            let assetPath = location.resolvingSymlinksInPath().path
            let policy = AVMutableAssetDownloadStorageManagementPolicy()
            policy.priority = .important
            policy.expirationDate = .distantFuture
            AVAssetDownloadStorageManager.shared().setStorageManagementPolicy(policy, for: location)
            // AVFoundation may use a system-managed asset container outside
            // the application home, especially on Simulator. Preserve that URL.
            let relative = assetPath.hasPrefix(home) ? String(assetPath.dropFirst(home.count)) : assetPath
            let enumerator = FileManager.default.enumerator(at: location, includingPropertiesForKeys: [.fileSizeKey])
            var size: Int64 = 0
            while let file = enumerator?.nextObject() as? URL {
                size += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let media = TelegramMedia(chatID: 0, messageID: Int64.random(in: 1...Int64.max), fileID: nil,
                name: request.displayTitle + ".movpkg", caption: candidate.providerName, date: .now, size: size,
                duration: 0, mimeType: "application/vnd.apple.mpegurl", thumbnailFileID: nil, kind: .video, remoteURL: nil)
            let record = TelegramSavedDownload(media: media, filename: "", savedAt: .now,
                catalogMedia: request.media, catalogEpisode: request.episode, sourceID: candidate.id, offlineAssetPath: relative)
            saved.insert(record, at: 0)
            do { try persist() } catch { saved.removeAll { $0.id == record.id }; throw error }
            await saveArtwork(mediaID: media.id, request: request)
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw error
        }
    }

    func begin(_ requestedMedia: TelegramMedia, store: TelegramStore) {
        // Resume the most complete known location for this release.
        let candidates = [requestedMedia] + tracked.values.map { $0.0 } + Array(rawTracked.values) + store.recentMedia
        let media = candidates.filter { OfflineLibraryIndex.sameRelease($0, requestedMedia) }.max {
            (store.files[$0.fileID ?? -1]?.downloadedSize ?? 0) < (store.files[$1.fileID ?? -1]?.downloadedSize ?? 0)
        } ?? requestedMedia
        if media.fileID != nil, let request = requestedMedia.fileID.flatMap({ tracked[$0]?.1 }) { track(media, request: request, store: store) }
        else { trackRaw(media, store: store) }
        guard let id = media.fileID, !cancelling.contains(id), !deleting.contains(id), tasks[id] == nil, !saved.contains(where: { OfflineLibraryIndex.sameRelease($0.media, media) && !$0.isCached }),
              !active.values.contains(where: { OfflineLibraryIndex.sameRelease($0, media) }) else { return }
        active[id] = media; errors[id] = nil
        updateProgress("telegram:\(id)", received: store.files[id]?.downloadedSize ?? 0, total: store.files[id]?.size ?? media.size)
        if store.files[id] == nil { transferSamples["telegram:\(id)"] = nil }
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil; self?.active[id] = nil; self?.finishProgress("telegram:\(id)") }
            do {
                guard let self else { return }
                let lease = try await CacheUsage.shared.waitForReader(); defer { lease.release() }
                if let cached = saved.first(where: { OfflineLibraryIndex.sameRelease($0.media, media) && $0.isCached }), FileManager.default.fileExists(atPath: cached.url.path) {
                    updateProgress("telegram:\(id)", received: cached.media.size, total: cached.media.size)
                    try await saveCompleted(media, path: cached.url.path, id: id); return
                }
                try await startOfflineTransfer(transport: store.transport, fileID: id)
                while true {
                    try Task.checkCancellation()
                    let response = try await store.transport.call("getFile", ["file_id": .integer(Int64(id))])
                    guard let file = TelegramFile(response) else { throw TelegramError(code: -1, message: "Telegram returned an invalid file.") }
                    if (store.files[id]?.downloadedSize ?? 0) <= file.downloadedSize { store.files[id] = file }
                    completed(file)
                    if file.completed {
                        try await self.saveCompleted(media, path: file.localPath, id: id); break
                    }
                    if !file.downloading { throw TelegramError(code: -1, message: "Download stopped. Tap Download to retry.") }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch { if !Task.isCancelled { self?.errors[id] = error.localizedDescription } }
        }
    }
    private func saveCompleted(_ media: TelegramMedia, path: String, id: Int) async throws {
        let ext = (media.name as NSString).pathExtension
        let filename = "offline-" + UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let destination = TelegramSavedDownload.directory.appending(path: filename)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: TelegramSavedDownload.directory, withIntermediateDirectories: true)
            do { try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
        }.value
        do { try Task.checkCancellation() } catch { try? FileManager.default.removeItem(at: destination); throw error }
        let previous = saved.first { OfflineLibraryIndex.sameRelease($0.media, media) }
        let request = tracked[id]?.1 ?? previous?.request
        saved.removeAll { $0.id == media.id }
        saved.insert(TelegramSavedDownload(media: media, filename: filename, savedAt: .now, catalogMedia: request?.media, catalogEpisode: request?.episode, artworkFilename: previous?.artworkFilename, rowArtworkFilename: previous?.rowArtworkFilename, titleArtworkFilename: previous?.titleArtworkFilename), at: 0)
        do { try persist() } catch {
            saved.removeAll { $0.id == media.id }; if let previous { saved.insert(previous, at: 0) }
            try? FileManager.default.removeItem(at: destination); throw error
        }
        if previous?.artworkFilename == nil, let request { await saveArtwork(mediaID: media.id, request: request) }
    }
    func cancelWeb(_ id: String) { webTasks[id]?.cancel() }
    func cancel(_ id: Int, store: TelegramStore) {
        guard cancelling.insert(id).inserted else { return }
        let task = tasks[id]
        task?.cancel()
        Task {
            defer { cancelling.remove(id) }
            _ = try? await store.transport.call("cancelDownloadFile", ["file_id": .integer(Int64(id)), "only_if_pending": .bool(false)])
            await task?.value
        }
    }
    func remove(_ item: TelegramSavedDownload) throws {
        guard !item.isCached else { throw TelegramError(code: -1, message: "Use Settings → Cache & Storage to clear cached videos.") }
        let lease = try CacheUsage.shared.eviction(); defer { lease.release() }
        let copies = saved.filter { !$0.isCached && OfflineLibraryIndex.sameRelease($0.media, item.media) }
        for copy in copies where FileManager.default.fileExists(atPath: copy.url.path) { try FileManager.default.removeItem(at: copy.url) }
        let ids = Set(copies.map(\.id)); saved.removeAll { ids.contains($0.id) && !$0.isCached }
        cleanupArtwork(copies); try persist()
    }
    func clearDownloads() throws {
        let lease = try CacheUsage.shared.eviction(); defer { lease.release() }
        let copies = saved.filter { !$0.isCached }
        for item in copies where FileManager.default.fileExists(atPath: item.url.path) { try FileManager.default.removeItem(at: item.url) }
        saved.removeAll { !$0.isCached }; cleanupArtwork(copies); try persist()
    }
    func refreshAfterCacheCleanup(removeArtwork: Bool) {
        let cached = saved.filter(\.isCached)
        if removeArtwork {
            for index in saved.indices where saved[index].isCached { saved[index].artworkFilename = nil; saved[index].rowArtworkFilename = nil; saved[index].titleArtworkFilename = nil }
            cleanupArtwork(cached)
        }
        discardMissingRecords(); try? persist()
    }
    private func cleanupArtwork(_ removed: [TelegramSavedDownload]) {
        let retained = Set(saved.flatMap { $0.artworkFilenames })
        for name in Set(removed.flatMap { $0.artworkFilenames }).subtracting(retained) {
            try? FileManager.default.removeItem(at: TelegramSavedDownload.directory.appending(path: name))
        }
    }
    private func discardMissingRecords() {
        let missing = saved.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        let missingIDs = Set(missing.map(\.id)); saved.removeAll { missingIDs.contains($0.id) }
        cleanupArtwork(missing)
    }
    func nextAvailable(after request: PlaybackRequest, library: LibraryStore) -> PlaybackRequest? {
        guard let episode = request.episode else { return nil }
        return saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }.compactMap(\.request).filter {
            $0.media.artworkIdentityKey == request.media.artworkIdentityKey &&
            ($0.episode?.seasonNumber ?? 0, $0.episode?.number ?? 0) > (episode.seasonNumber, episode.number) && !library.isWatched($0)
        }.sorted { ($0.episode?.seasonNumber ?? 0, $0.episode?.number ?? 0) < ($1.episode?.seasonNumber ?? 0, $1.episode?.number ?? 0) }.first
    }
    private func persist() throws {
        var directory = TelegramSavedDownload.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(saved).write(to: manifest, options: .atomic)
    }
}

@MainActor @Observable final class OfflineConnectivity {
    static let shared = OfflineConnectivity()
    var isOffline = false
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { path in
            let offline = path.status == .unsatisfied
            Task { @MainActor in OfflineConnectivity.shared.isOffline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "Velagram.connectivity"))
    }
}

private final class OfflineDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission: TimeInterval = 0
    let update: @Sendable (Int64, Int64) -> Void
    init(update: @escaping @Sendable (Int64, Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        let emit = lock.withLock {
            guard now - lastEmission >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite else { return false }
            lastEmission = now; return true
        }
        if emit { update(totalBytesWritten, totalBytesExpectedToWrite) }
    }
}


/// AVFoundation keeps adaptive video, audio and playlist metadata together in an
/// offline package. Byte counts are unknown; progress is measured in media time.
private final class OfflineHLSDownload: NSObject, AVAssetDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var location: URL?
    private var task: AVAssetDownloadTask?
    private var cancelled = false
    private var update: (@Sendable (Double) -> Void)?
    private lazy var session: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "myko.offline.hls." + UUID().uuidString)
        configuration.sessionSendsLaunchEvents = false
        return AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    func download(source: PlaybackSource, title: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw TelegramError(code: -1, message: "Live streams cannot be saved as a complete offline video. Choose an on-demand source.")
        }
        guard try await !asset.load(.hasProtectedContent) else {
            throw TelegramError(code: -1, message: "This source requires an offline license from its provider. Try another source for this title.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.update = progress
                let task = session.makeAssetDownloadTask(asset: asset, assetTitle: title, assetArtworkData: nil, options: nil)
                self.task = task
                lock.unlock()
                guard let task else { finish(error: AppError.noStream); return }
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        lock.withLock { self.location = location }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        lock.withLock { self.location = location }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        let total = timeRangeExpectedToLoad.duration.seconds
        guard total.isFinite, total > 0 else { return }
        let received = loadedTimeRanges.reduce(0) { $0 + $1.timeRangeValue.duration.seconds }
        guard received.isFinite else { return }
        let callback = lock.withLock { update }
        callback?(min(1, max(0, received / total)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }

    private func finish(error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let location = self.location
        let cancelled = self.cancelled
        lock.unlock()
        if let error = error ?? (cancelled ? CancellationError() : nil) {
            if let location { try? FileManager.default.removeItem(at: location) }
            continuation?.resume(throwing: error)
        } else if let location, task?.urlAsset.assetCache?.isPlayableOffline == true {
            continuation?.resume(returning: location)
        } else {
            if let location { try? FileManager.default.removeItem(at: location) }
            continuation?.resume(throwing: AppError.noStream)
        }
        session.finishTasksAndInvalidate()
    }
}

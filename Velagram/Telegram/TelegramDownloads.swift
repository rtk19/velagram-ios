import Foundation
import Observation

struct TelegramSavedDownload: Identifiable, Codable, Hashable {
    var id: String { media.id }
    let media: TelegramMedia
    let filename: String
    let savedAt: Date
    var url: URL { Self.directory.appending(path: filename) }
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Velagram/TelegramDownloads") }
}

@MainActor @Observable final class TelegramDownloads {
    static let shared = TelegramDownloads()
    var saved: [TelegramSavedDownload] = []
    var active: [Int: TelegramMedia] = [:]
    var errors: [Int: String] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var manifest: URL { TelegramSavedDownload.directory.appending(path: "downloads.json") }
    init() { reload() }
    func reload() {
        if let data = try? Data(contentsOf: manifest), let records = try? JSONDecoder().decode([TelegramSavedDownload].self, from: data) { saved = records.filter { FileManager.default.fileExists(atPath: $0.url.path) } }
        else { saved = [] }
    }
    func local(_ media: TelegramMedia) -> URL? { saved.first { $0.id == media.id }?.url }
    func begin(_ media: TelegramMedia, store: TelegramStore) {
        guard let id = media.fileID, tasks[id] == nil, local(media) == nil else { return }
        active[id] = media; errors[id] = nil
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil; self?.active[id] = nil }
            do {
                let lease = try await CacheUsage.shared.waitForReader(); defer { lease.release() }
                _ = try await store.transport.call("downloadFile", ["file_id": .integer(Int64(id)), "priority": .integer(8), "offset": .integer(0), "limit": .integer(0), "synchronous": .bool(false)])
                while true {
                    try Task.checkCancellation()
                    let response = try await store.transport.call("getFile", ["file_id": .integer(Int64(id))])
                    guard let file = TelegramFile(response) else { throw TelegramError(code: -1, message: "Telegram returned an invalid file.") }
                    store.files[id] = file
                    if file.completed {
                        let ext = (media.name as NSString).pathExtension
                        let filename = "\(media.chatID)-\(media.messageID)-\(id)" + (ext.isEmpty ? "" : ".\(ext)")
                        let destination = TelegramSavedDownload.directory.appending(path: filename)
                        try await Task.detached(priority: .utility) {
                            try FileManager.default.createDirectory(at: TelegramSavedDownload.directory, withIntermediateDirectories: true)
                            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: URL(fileURLWithPath: file.localPath), to: destination) }
                        }.value
                        guard let self else { return }
                        saved.removeAll { $0.id == media.id }
                        saved.insert(TelegramSavedDownload(media: media, filename: filename, savedAt: .now), at: 0)
                        try persist(); break
                    }
                    if !file.downloading { throw TelegramError(code: -1, message: "Download stopped. Tap Download to retry.") }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch { if !Task.isCancelled { self?.errors[id] = error.localizedDescription } }
        }
    }
    func cancel(_ id: Int, store: TelegramStore) {
        tasks[id]?.cancel()
        Task { _ = try? await store.transport.call("cancelDownloadFile", ["file_id": .integer(Int64(id)), "only_if_pending": .bool(false)]) }
    }
    func remove(_ item: TelegramSavedDownload) throws {
        try FileManager.default.removeItem(at: item.url)
        saved.removeAll { $0.id == item.id }; try persist()
    }
    private func persist() throws { try JSONEncoder().encode(saved).write(to: manifest, options: .atomic) }
}

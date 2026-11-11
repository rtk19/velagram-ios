import Foundation
import Testing
@testable import Velagram

func fixture(_ text: String) throws -> TelegramJSON { try JSONDecoder().decode(TelegramJSON.self, from: Data(text.utf8)) }

actor TelegramFixtureTransport: TelegramTransport {
    nonisolated let updates: AsyncStream<TelegramJSON> = AsyncStream { $0.finish() }
    var queries: [TelegramJSON] = []
    var handler: @Sendable (TelegramJSON) throws -> TelegramJSON
    init(handler: @escaping @Sendable (TelegramJSON) throws -> TelegramJSON = { _ in .request("ok") }) { self.handler = handler }
    func request(_ query: TelegramJSON, timeout: TimeInterval) async throws -> TelegramJSON { queries.append(query); return try handler(query) }
    func calls() -> [TelegramJSON] { queries }
}

struct TelegramTests {
    func media(name: String, caption: String = "", id: Int64 = 1, chatID: Int64 = 10, kind: TelegramMedia.Kind = .video) -> TelegramMedia {
        TelegramMedia(chatID: chatID, messageID: id, fileID: Int(id), name: name, caption: caption,
            date: Date(timeIntervalSince1970: Double(id)), size: 100, duration: 60, mimeType: kind == .video ? "video/mp4" : "application/octet-stream", thumbnailFileID: nil, kind: kind, remoteURL: nil)
    }
    @Test func jsonRetainsTelegramMessageAndChatIdentifiers() throws {
        let value = try fixture(#"{"chat_id":-1001234567890,"id":4503599627370495,"@extra":"test","ok":true}"#)
        #expect(value["id"].int64 == 4_503_599_627_370_495)
        #expect(value["chat_id"].int64 == -1_001_234_567_890)
        #expect(try JSONDecoder().decode(TelegramJSON.self, from: JSONEncoder().encode(value)) == value)
    }
    @Test(arguments: [("Show.S01E02.1080p.mkv", 1, 2), ("Show_S01E02_1080p.mkv", 1, 2), ("Show 2x10.mkv", 2, 10), ("סדרה עונה 3 פרק 12.mp4", 3, 12), ("סדרה ע2פ4.mkv", 2, 4), ("Show season 1 episode 20", 1, 20)])
    func identifiesMultilingualEpisodes(input: (String, Int, Int)) {
        #expect(TelegramClassification.episode(in: input.0) == TelegramEpisode(season: input.1, episode: input.2))
    }
    @Test func classifiesMoviesSeriesAndOtherFilesWithOverrides() {
        #expect(TelegramClassification.category(media(name: "Film.2025.1080p.mp4")) == .movies)
        #expect(TelegramClassification.category(media(name: "Show.S01E02.mkv")) == .series)
        #expect(TelegramClassification.category(media(name: "Recording.mp4"), chatTitle: "סדרות") == .series)
        #expect(TelegramClassification.category(media(name: "Film.mp4"), override: .series) == .series)
        #expect(TelegramClassification.category(media(name: "notes.txt", kind: .document)) == .all)
        #expect(TelegramClassification.category(media(name: "subtitle.srt", kind: .document)) == .all)
    }
    @Test func groupsReleasesAndOrdersSeasonsNumerically() {
        let items = [media(name: "Show.S02E01.1080p.mkv", id: 1), media(name: "Show.S01E10.720p.mkv", id: 2), media(name: "Show.S01E02.1080p.mkv", id: 3)]
        let groups = TelegramSeries.group(items)
        #expect(groups.count == 1)
        #expect(groups[0].title == "Show")
        #expect(groups[0].episodes.map(\.messageID) == [3, 2, 1])
    }
    @Test func documentVideosAndCaptionsRetainStableIdentity() throws {
        let message = try fixture(#"{"id":12345,"chat_id":-100123,"date":100,"content":{"@type":"messageDocument","caption":{"text":"Series S02E04"},"document":{"file_name":"Series.S02E04.mkv","mime_type":"video/x-matroska","document":{"@type":"file","id":77,"size":5000000000},"thumbnail":{"file":{"id":80}}}}}"#)
        let item = try #require(TelegramMedia.parse(message))
        #expect(item.isVideo)
        #expect(item.id == "-100123:12345")
        #expect(item.size == 5_000_000_000)
        #expect(item.thumbnailFileID == 80)
        #expect(item.episode == TelegramEpisode(season: 2, episode: 4))
    }
    @Test func extractsPlayableLinksWithoutTreatingEveryMessageAsMedia() throws {
        let link = try fixture(#"{"id":1,"chat_id":2,"date":10,"content":{"@type":"messageText","text":{"text":"Watch https://example.com/video.mp4?token=abc","entities":[]}}}"#)
        #expect(TelegramMedia.parse(link)?.remoteURL?.absoluteString == "https://example.com/video.mp4?token=abc")
        let plain = try fixture(#"{"id":2,"chat_id":2,"content":{"@type":"messageText","text":{"text":"No attachment"}}}"#)
        #expect(TelegramMedia.parse(plain) == nil)
    }
    @Test func byteRangesSupportSeekingSuffixesAndRejectInvalidRanges() throws {
        #expect(try TelegramByteRange.parse(nil, size: 100) == TelegramByteRange(start: 0, end: 99))
        #expect(try TelegramByteRange.parse("bytes=20-29", size: 100).count == 10)
        #expect(try TelegramByteRange.parse("bytes=90-", size: 100) == TelegramByteRange(start: 90, end: 99))
        #expect(try TelegramByteRange.parse("bytes=-10", size: 100) == TelegramByteRange(start: 90, end: 99))
        #expect(try TelegramByteRange.parse("bytes=90-500", size: 100).end == 99)
        for invalid in ["bytes=100-", "bytes=30-20", "bytes=0-5,10-20", "bytes=-0", "garbage"] {
            #expect(throws: TelegramError.self) { try TelegramByteRange.parse(invalid, size: 100) }
        }
    }
    @MainActor @Test func categoryOverridesAndPinsSurviveRelaunch() throws {
        let suite = "TelegramTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let transport = TelegramFixtureTransport()
        let store = TelegramStore(transport: transport, defaults: defaults)
        let chat = try #require(TelegramChat(try fixture(#"{"id":10,"title":"My collection","type":{"@type":"chatTypeSupergroup"}}"#)))
        store.mark(chat, as: .series); store.togglePin(chat)
        let file = media(name: "Unknown.mp4")
        store.mark(file, as: .movies)
        let restored = TelegramStore(transport: transport, defaults: defaults)
        #expect(restored.pinned == [10])
        #expect(restored.chatCategories["10"] == .series)
        #expect(restored.category(file) == .movies)
    }
    @MainActor @Test func readsTelegramFolderTitlesInOldAndFormattedFormats() async throws {
        let store = TelegramStore(transport: TelegramFixtureTransport())
        await store.consume(try fixture(#"{"@type":"updateChatFolders","chat_folders":[{"id":1,"title":"Movies"},{"id":2,"title":{"text":"סדרות"}},{"id":3,"name":{"@type":"chatFolderName","text":{"@type":"formattedText","text":"Media","entities":[]},"animate_custom_emoji":false}}]}"#))
        #expect(store.folders.map(\.title) == ["Movies", "סדרות", "Media"])
    }
    @MainActor @Test func paginatedChatSearchDoesNotDuplicateBoundaryMessages() async throws {
        let first = try fixture(#"{"id":100,"chat_id":10,"date":100,"content":{"@type":"messageVideo","caption":{"text":""},"video":{"file_name":"Show.S01E01.mp4","video":{"@type":"file","id":1,"size":10}}}}"#)
        let second = try fixture(#"{"id":90,"chat_id":10,"date":90,"content":{"@type":"messageVideo","caption":{"text":""},"video":{"file_name":"Show.S01E02.mp4","video":{"@type":"file","id":2,"size":10}}}}"#)
        let transport = TelegramFixtureTransport { query in
            if query.type == "searchChatMessages" {
                guard query["filter"].type == "searchMessagesFilterVideo" else { return .request("foundChatMessages", ["messages": .array([])]) }
                if query["from_message_id"].int == 0 { return .request("foundChatMessages", ["messages": .array([first]), "next_from_message_id": .integer(100)]) }
                return .request("foundChatMessages", ["messages": .array([first, second]), "next_from_message_id": .integer(0)])
            }
            return .request("chat", ["id": .integer(10), "title": .string("Test")])
        }
        let store = TelegramStore(transport: transport)
        store.authorization = .request("authorizationStateReady")
        let browser = TelegramMediaBrowser(store: store, chatID: 10)
        await browser.reset(query: "Show")
        #expect(browser.media.count == 1); #expect(browser.hasMore)
        await browser.loadMore()
        #expect(browser.media.map(\.messageID) == [100, 90]); #expect(!browser.hasMore)
        #expect(await transport.calls().contains { $0["query"].string == "Show" && $0["from_message_id"].int == 100 })
    }
    @Test func loopbackStreamServesExactRangesAndRejectsWrongToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data((0..<256).map(UInt8.init))
        let path = directory.appending(path: "fixture.mp4"); try bytes.write(to: path)
        let file = TelegramJSON.request("file", ["id": .integer(7), "size": .integer(256), "local": .object(["path": .string(path.path), "downloaded_size": .integer(256), "is_downloading_completed": .bool(true)])])
        let transport = TelegramFixtureTransport { query in query.type == "getFile" ? file : .request("fileDownloadedPrefixSize", ["size": .integer(256)]) }
        let item = TelegramMedia(chatID: 1, messageID: 1, fileID: 7, name: "fixture.mp4", caption: "", date: .now, size: 256, duration: 1, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: nil)
        let server = try TelegramStreamServer(transport: transport, media: item)
        defer { server.stop() }
        let url = try await server.start(filename: item.name)
        #expect(url.host == "127.0.0.1")
        var request = URLRequest(url: url); request.setValue("bytes=100-119", forHTTPHeaderField: "Range")
        let (result, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes 100-119/256")
        #expect(result == bytes.subdata(in: 100..<120))
        var wrong = URLComponents(url: url, resolvingAgainstBaseURL: false)!; wrong.path = "/wrong/token"
        let (_, denied) = try await URLSession.shared.data(from: wrong.url!)
        #expect((denied as? HTTPURLResponse)?.statusCode == 404)
        request.setValue("bytes=999-", forHTTPHeaderField: "Range")
        let (_, unsatisfiable) = try await URLSession.shared.data(for: request)
        #expect((unsatisfiable as? HTTPURLResponse)?.statusCode == 416)
    }
    @Test func streamReportsTelegramDownloadErrorsInsteadOfBufferingForever() async throws {
        let transport = TelegramFixtureTransport { _ in throw TelegramError(code: 400, message: "File is unavailable") }
        try await confirmation { reported in
            let server = try TelegramStreamServer(transport: transport, media: media(name: "missing.mp4")) { message in
                #expect(message == "File is unavailable")
                reported()
            }
            defer { server.stop() }
            let url = try await server.start(filename: "missing.mp4")
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
        }
    }
    @MainActor @Test func backupRestoresOrganizationAndSavedDownloadsWithoutSessionCredentials() throws {
        let suite = "TelegramBackupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "Velagram")
        let downloads = support.appending(path: "TelegramDownloads")
        let session = root.appending(path: "VelagramTelegramSession")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("offline-media".utf8).write(to: downloads.appending(path: "saved.mp4"))
        try Data("private-session".utf8).write(to: session.appending(path: "td.binlog"))
        let transport = TelegramFixtureTransport()
        let store = TelegramStore(transport: transport, defaults: defaults)
        store.mark(media(name: "A.mp4"), as: .series)
        let backup = UserDataBackupService(applicationSupportDirectory: support, userDefaults: defaults, preferencesDomain: suite, appVersion: "1.1.0")
        let data = try backup.exportData()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: downloads.appending(path: "saved.mp4"))
        try backup.restore(from: data)
        let restored = TelegramStore(transport: transport, defaults: defaults)
        #expect(restored.category(media(name: "A.mp4")) == .series)
        #expect(try Data(contentsOf: downloads.appending(path: "saved.mp4")) == Data("offline-media".utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let archived = try #require(object["applicationSupportFiles"] as? [[String: Any]])
        #expect(archived.count == 1)
        #expect(archived.first?["relativePath"] as? String == "TelegramDownloads/saved.mp4")
        #expect(try Data(contentsOf: session.appending(path: "td.binlog")) == Data("private-session".utf8))
    }
    @Test func nativeTDLibRespondsWithoutAnAccount() async throws {
        let result = try await TDLibTransport.shared.call("getTextEntities", ["text": .string("Visit https://telegram.org")])
        #expect(result.type == "textEntities")
        #expect(!result["entities"].array.isEmpty)
    }
}

import Foundation
import Observation

@MainActor @Observable final class TelegramMediaBrowser {
    let store: TelegramStore
    let chatID: Int64?
    var media: [TelegramMedia] = []
    var topics: [TelegramTopic] = []
    var topicID: Int64?
    var loading = false
    var failure: String?
    var hasMore = true
    var query = ""
    private var cursors: [String: TelegramJSON] = [:]
    private var finished: Set<String> = []
    private var generation = UUID()
    // Documents include MKV files and subtitle/playlist attachments. URL messages
    // retain directly playable links. Telegram supplies these searches itself.
    private let filters = ["searchMessagesFilterVideo", "searchMessagesFilterDocument", "searchMessagesFilterAudio", "searchMessagesFilterUrl"]
    init(store: TelegramStore, chatID: Int64?) { self.store = store; self.chatID = chatID }

    func reset(query: String, topicID: Int64? = nil) async {
        generation = UUID(); self.query = query; self.topicID = topicID
        media = []; cursors = [:]; finished = []; hasMore = true; loading = false
        await loadMore()
    }
    func loadMore() async {
        guard !loading, hasMore, store.ready else { return }
        let token = generation
        loading = true; failure = nil
        defer { if generation == token { loading = false } }
        do {
            var batch: [TelegramMedia] = []
            for filter in filters where !finished.contains(filter) {
                try Task.checkCancellation()
                let response: TelegramJSON
                if let chatID {
                    var fields: [String: TelegramJSON] = ["chat_id": .integer(chatID), "query": .string(query),
                        "from_message_id": cursors[filter] ?? .integer(0), "offset": .integer(0), "limit": .integer(50),
                        "filter": .request(filter), "message_thread_id": .integer(topicID ?? 0), "saved_messages_topic_id": .integer(0)]
                    if let topicID { fields["topic_id"] = .request("messageTopicForum", ["forum_topic_id": .integer(topicID)]) }
                    response = try await store.transport.call("searchChatMessages", fields)
                } else {
                    response = try await store.transport.call("searchMessages", ["query": .string(query), "offset": cursors[filter] ?? .string(""), "limit": .integer(50),
                        "filter": .request(filter), "min_date": .integer(0), "max_date": .integer(0)])
                }
                guard token == generation else { return }
                let messages = response["messages"].array
                let page = messages.compactMap(TelegramMedia.parse)
                batch += page
                if chatID != nil {
                    let old = cursors[filter]?.int64 ?? 0
                    let next = response["next_from_message_id"].int64 ?? messages.last?["id"].int64 ?? 0
                    if messages.isEmpty || next == 0 || next == old { finished.insert(filter) }
                    else { cursors[filter] = .integer(next) }
                } else {
                    let next = response["next_offset"].string ?? ""
                    if next.isEmpty || next == cursors[filter]?.string { finished.insert(filter) }
                    else { cursors[filter] = .string(next) }
                }
                // File progress events start before getFile has been requested.
                for message in messages { collectFiles(message["content"]) }
            }
            guard token == generation else { return }
            var seen = Set(media.map(\.id))
            media += batch.filter { seen.insert($0.id).inserted }
            media = TelegramClassification.sorted(media, by: .newest)
            hasMore = finished.count < filters.count
            for id in Set(batch.map(\.chatID)) where store.chats[id] == nil {
                if let chat = TelegramChat(try await store.transport.call("getChat", ["chat_id": .integer(id)])) { store.chats[id] = chat }
            }
        } catch { if token == generation, !Task.isCancelled { failure = error.localizedDescription } }
    }
    private func collectFiles(_ value: TelegramJSON) {
        if value.type == "file", let file = TelegramFile(value) { store.files[file.id] = file; return }
        switch value {
        case .object(let fields): fields.values.forEach(collectFiles)
        case .array(let array): array.forEach(collectFiles)
        default: break
        }
    }
    func loadTopics() async {
        guard let chatID else { return }
        do {
            var nextDate: Int64 = 0, nextMessage: Int64 = 0, nextTopic: Int64 = 0
            var collected: [TelegramTopic] = []
            var seen = Set<Int64>()
            repeat {
                try Task.checkCancellation()
                let response = try await store.transport.call("getForumTopics", ["chat_id": .integer(chatID), "query": .string(""),
                    "offset_date": .integer(nextDate), "offset_message_id": .integer(nextMessage),
                    "offset_message_thread_id": .integer(nextTopic), "offset_forum_topic_id": .integer(nextTopic), "limit": .integer(100)])
                let page = response["topics"].array
                for entry in page {
                    let info = entry["info"]
                    if let id = info["forum_topic_id"].int64 ?? info["message_thread_id"].int64, seen.insert(id).inserted {
                        collected.append(TelegramTopic(id: id, title: info["name"].string ?? "Topic"))
                    }
                }
                let previous = nextTopic
                nextDate = response["next_offset_date"].int64 ?? 0
                nextMessage = response["next_offset_message_id"].int64 ?? 0
                nextTopic = response["next_offset_forum_topic_id"].int64 ?? response["next_offset_message_thread_id"].int64 ?? 0
                topics = collected
                if page.isEmpty || nextTopic == 0 || previous == nextTopic { break }
            } while true
        } catch { /* Normal groups and channels do not have forum topics. */ }
    }
}

struct TelegramSeries: Identifiable, Sendable {
    var id: String { key }
    let key: String
    let title: String
    let episodes: [TelegramMedia]
    static func group(_ items: [TelegramMedia]) -> [TelegramSeries] {
        Dictionary(grouping: items, by: \.seriesKey).map { key, entries in
            TelegramSeries(key: key, title: entries.first?.title ?? key, episodes: TelegramClassification.sorted(entries, by: .episode))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

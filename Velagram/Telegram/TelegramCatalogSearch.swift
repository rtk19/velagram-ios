import Foundation

/// Matches a catalog selection against Telegram filenames and captions without
/// requiring the viewer to know which chat contains a release.
enum TelegramSearchLanguage: String, CaseIterable, Identifiable {
    case hebrew, english
    static let defaultsKey = "telegram.search.firstLanguage"
    var id: String { rawValue }
    var title: String { self == .hebrew ? "Hebrew first" : "English first" }
    static var preferred: Self { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "english") ?? .english }
}

struct TelegramScanProgress: Sendable {
    var completed: Int
    var total: Int
    var task: String
}

enum TelegramCatalogMatching {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
    static func score(_ media: TelegramMedia, context: PlaybackLookupContext, chatTitle: String = "") -> Int? {
        guard media.isVideo || media.kind == .link else { return nil }
        let filename = normalized(TelegramClassification.cleanTitle(media.name))
        let caption = normalized(media.caption)
        let titles = Set(aliases(context).map(normalized).filter { !$0.isEmpty })
        // Whole token boundaries prevent “It” matching “Titanic”. Prefer an
        // exact cleaned filename; captions can contain the localized title.
        let exact = titles.contains(filename)
        let chat = normalized(chatTitle)
        let identityMatches = titles.contains { title in
            if (" " + caption + " ").contains(" " + title + " ") || (" " + filename + " ").contains(" " + title + " ") || (" " + chat + " ").contains(" " + title + " ") { return true }
            let compact = title.replacingOccurrences(of: " ", with: "")
            return compact.count >= 4 && compact.count <= 8 && title.split(separator: " ").allSatisfy { $0.count == 1 }
                && filename.range(of: "^" + compact.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*") + "(?:\\s|$)", options: .regularExpression) != nil
        }
        guard exact || identityMatches else { return nil }
        if let episode = context.request.episode {
            if let found = media.episode {
                guard found.season == episode.seasonNumber, found.episode == episode.number else { return nil }
            } else {
                // A season-specific chat can supply the missing season, but an
                // isolated episode number can never identify a season globally.
                let season = #"(?i)(?:season|עונה|(?<![A-Za-z])s)[ .,_:-]*0*"# + String(episode.seasonNumber) + #"(?!\d)"#
                let number = #"(?i)(?:episode|פרק|(?<![A-Za-z])e|^)[ .,_:-]*0*"# + String(episode.number) + #"(?!\d)"#
                guard chatTitle.range(of: season, options: .regularExpression) != nil,
                      (media.name + " " + media.caption).range(of: number, options: .regularExpression) != nil else { return nil }
            }
        } else {
            guard media.episode == nil else { return nil }
            if let year = context.request.media.releaseDate.flatMap({ Int($0.prefix(4)) }) {
                let years = matches(#"(?<!\d)(?:19|20)\d{2}(?!\d)"#, in: media.name).compactMap(Int.init)
                if !years.isEmpty, !years.contains(year) { return nil }
            }
        }
        return (exact ? 100 : 60) + (media.size > 0 ? 5 : 0)
    }
    static func aliases(_ context: PlaybackLookupContext) -> [String] {
        let primary = [context.request.media.title, context.request.media.originalTitle].compactMap { $0 }
        let hebrew = context.alternativeTitles.filter { $0.range(of: #"[א-ת]"#, options: .regularExpression) != nil }
        let latin = context.alternativeTitles.filter { $0.range(of: #"^[\p{Latin}\d\s\p{P}]+$"#, options: .regularExpression) != nil }
        var seen = Set<String>()
        var titles = (primary + hebrew + latin).map(normalized).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(8).map { $0 }
        for title in primary {
            let words = normalized(title).split(separator: " ")
            if words.count >= 4, words.count <= 8, words.allSatisfy({ $0.first?.isASCII == true }) {
                let acronym = words.compactMap(\.first).map(String.init).joined()
                titles += [acronym, acronym.map(String.init).joined(separator: ".")]
            }
        }
        return titles
    }
    static func queries(_ context: PlaybackLookupContext, language: TelegramSearchLanguage = .preferred) -> [String] {
        let titles = aliases(context)
        var queries = titles
        if let ep = context.request.episode {
            let codes = [String(format: "S%02dE%02d", ep.seasonNumber, ep.number), "S\(ep.seasonNumber)E\(ep.number)",
                         "season \(ep.seasonNumber) episode \(ep.number)", "עונה \(ep.seasonNumber) פרק \(ep.number)",
                         "ע\(ep.seasonNumber)פ\(ep.number)", "\(ep.seasonNumber)x\(ep.number)",
                         String(format: "S%02d E%02d", ep.seasonNumber, ep.number)]
            // Fair ordering gives each language and acronym an early request.
            queries = codes.prefix(2).flatMap { code in titles.map { $0 + " " + code } } + titles
                + codes.dropFirst(2).flatMap { code in titles.prefix(4).map { $0 + " " + code } }
        } else if let year = context.request.media.releaseDate.map({ String($0.prefix(4)) }) {
            queries = titles.map { $0 + " " + year } + titles
        }
        var seen = Set<String>()
        let unique = queries.filter { seen.insert($0.lowercased()).inserted }
        let preferred = unique.filter { ($0.range(of: "[א-ת]", options: .regularExpression) != nil) == (language == .hebrew) }
        let remaining = unique.filter { ($0.range(of: "[א-ת]", options: .regularExpression) != nil) != (language == .hebrew) }
        return Array((preferred + remaining).prefix(56))
    }
    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
    static func metadata(_ media: TelegramMedia) -> StreamDisplayMetadata {
        let text = media.name + " " + media.caption
        let quality = matches(#"(?<![A-Za-z0-9])(?:2160p|1080p|1080i|720p|576p|480p|360p|4k|8k)(?![A-Za-z0-9])"#, in: text).first?.uppercased()
        let ext = (media.name as NSString).pathExtension.uppercased()
        let container = ext.isEmpty ? media.mimeType.split(separator: "/").last.map(String.init)?.uppercased() : ext
        let release = matches(#"(?<![A-Za-z0-9])(?:WEB[ ._-]?DL|WEBRip|BluRay|BDRip|HDTV|REMUX|CAM|TS)(?![A-Za-z0-9])"#, in: text).first?.uppercased()
        return StreamDisplayMetadata(origin: "Telegram", quality: quality, sizeBytes: media.size > 0 ? media.size : nil,
                                     container: container, audioLanguage: nil, releaseType: release)
    }
}

struct TelegramCatalogSearch: Sendable {
    let transport: any TelegramTransport
    private struct Job: Sendable {
        let query: String
        let filter: String
        var offset = ""
        var chatID: Int64? = nil
        var id: String { "\(chatID ?? 0)|\(query)|\(filter)" }
    }
    private struct Page: Sendable {
        let job: Job
        let response: TelegramJSON?
        let error: String?
    }
    private func fetch(_ job: Job) async -> Page {
        do {
            try Task.checkCancellation()
            var fields: [String: TelegramJSON] = ["query": .string(job.query), "limit": .integer(100), "filter": .request(job.filter)]
            let method: String
            if let id = job.chatID {
                method = "searchChatMessages"
                fields["chat_id"] = .integer(id); fields["from_message_id"] = .integer(Int64(job.offset) ?? 0)
                fields["offset"] = .integer(0)
            } else {
                method = "searchMessages"; fields["offset"] = .string(job.offset)
                fields["min_date"] = .integer(0); fields["max_date"] = .integer(0)
            }
            return Page(job: job, response: try await transport.call(method, fields, timeout: 10), error: nil)
        } catch { return Page(job: job, response: nil, error: error.localizedDescription) }
    }
    func search(context: PlaybackLookupContext, pages: Int = 2,
                onProgress: @escaping @Sendable (TelegramScanProgress) async -> Void = { _ in },
                onBatch: @escaping @Sendable ([TelegramMedia]) async -> Void) async throws {
        var found: [String: TelegramMedia] = [:]
        var chatNames: [Int64: String] = [:]
        var succeeded = false
        var lastError: String?
        let language = TelegramSearchLanguage.preferred
        let titles = TelegramCatalogMatching.aliases(context).sorted {
            let left = $0.range(of: "[א-ת]", options: .regularExpression) != nil
            let right = $1.range(of: "[א-ת]", options: .regularExpression) != nil
            return left != right && left == (language == .hebrew)
        }
        var jobs = TelegramCatalogMatching.queries(context).flatMap { query in
            ["searchMessagesFilterVideo", "searchMessagesFilterDocument"].map { Job(query: query, filter: $0) }
        }
        jobs += titles.prefix(3).map { Job(query: $0, filter: "searchMessagesFilterUrl") }
        // Search chat names concurrently, so a slow chat lookup never delays
        // the first global file matches. Add targeted jobs after the first pass.
        let discovery = Task { () -> ([Job], [Int64: String]) in
            var targeted: [Job] = []; var names: [Int64: String] = [:]
            guard let ep = context.request.episode else { return (targeted, names) }
            var ids = Set<Int64>()
            for title in titles.prefix(3) {
                guard !Task.isCancelled else { return (targeted, names) }
                for method in ["searchChats", "searchChatsOnServer"] {
                    if let response = try? await transport.call(method, ["query": .string(title), "limit": .integer(20)], timeout: 5) {
                        ids.formUnion(response["chat_ids"].array.compactMap(\.int64))
                    }
                }
            }
            for id in ids.prefix(12) {
                guard !Task.isCancelled else { return (targeted, names) }
                if let json = try? await transport.call("getChat", ["chat_id": .integer(id)], timeout: 5), let chat = TelegramChat(json) {
                    names[id] = chat.title
                    for query in [String(ep.number), String(format: "S%02dE%02d", ep.seasonNumber, ep.number)] {
                        for filter in ["searchMessagesFilterVideo", "searchMessagesFilterDocument"] { targeted.append(Job(query: query, filter: filter, chatID: id)) }
                    }
                }
            }
            return (targeted, names)
        }
        defer { discovery.cancel() }
        var completed = 0
        var total = jobs.count
        await onProgress(.init(completed: completed, total: total, task: "Finding matching chats and planning searches…"))
        for round in 0..<max(2, pages) {
            try Task.checkCancellation()
            if jobs.isEmpty { break }
            var nextJobs: [Job] = []
            let currentJobs = jobs
            await onProgress(.init(completed: completed, total: total, task: "Searching: " + (currentJobs.first?.query ?? "")))
            try await withThrowingTaskGroup(of: Page.self) { group in
                var index = 0
                var active: [String: String] = [:]
                func enqueue() {
                    guard index < currentJobs.count else { return }
                    let job = currentJobs[index]; index += 1
                    active[job.id] = job.query
                    group.addTask { await fetch(job) }
                }
                for _ in 0..<min(3, currentJobs.count) { enqueue() }
                defer { group.cancelAll() }
                for try await page in group {
                    try Task.checkCancellation()
                    active.removeValue(forKey: page.job.id)
                    enqueue()
                    completed += 1
                    let nextQuery = active.values.sorted().joined(separator: " · ")
                    await onProgress(.init(completed: completed, total: total, task: "Searching: " + nextQuery + " · pass \(round + 1)"))
                    guard let response = page.response else { lastError = page.error; continue }
                    succeeded = true
                    let messages = response["messages"].array
                    let previousCount = found.count
                    for media in messages.compactMap(TelegramMedia.parse) where TelegramCatalogMatching.score(media, context: context, chatTitle: chatNames[media.chatID] ?? "") != nil {
                        found[media.id] = media
                    }
                    let ranked = found.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
                    if found.count != previousCount { await onBatch(ranked) }
                    var next = page.job
                    let offset = page.job.chatID == nil ? response["next_offset"].string ?? "" : String(response["next_from_message_id"].int64 ?? messages.last?["id"].int64 ?? 0)
                    if !messages.isEmpty, !offset.isEmpty, offset != "0", offset != page.job.offset {
                        next.offset = offset; nextJobs.append(next)
                    }
                }
            }
            if round == 0 {
                let (targeted, names) = await discovery.value
                chatNames.merge(names) { _, new in new }; nextJobs += targeted
            }
            if round + 1 < max(2, pages) { total += nextJobs.count }
            jobs = nextJobs
        }
        await onProgress(.init(completed: completed, total: total, task: "Telegram scan complete"))
        if !succeeded, let lastError { throw TelegramError(code: -1, message: lastError) }
    }
}

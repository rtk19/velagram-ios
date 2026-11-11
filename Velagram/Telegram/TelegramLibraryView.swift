import SwiftUI

struct TelegramRootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var store = TelegramStore.shared
    @State private var category: TelegramCategory = .all
    @State private var showChats = true
    @State private var folderID: Int?
    @State private var query = ""
    @State private var searchedChats: [TelegramChat] = []
    @State private var adding = false
    @State private var downloads = false
    @State private var account = false
    @State private var resumeMedia: TelegramMedia?
    private var visibleChats: [TelegramChat] {
        let chats = query.isEmpty ? store.chatOrder.compactMap { store.chats[$0] } : searchedChats
        return chats.enumerated().sorted { left, right in
            let l = store.pinned.contains(left.element.id), r = store.pinned.contains(right.element.id)
            return l == r ? left.offset < right.offset : l
        }.map(\.element)
    }
    var body: some View {
        Group {
            if store.ready {
                VStack(spacing: 0) {
                    HStack {
                        Button { showChats = true } label: { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                            .buttonStyle(.borderedProminent).tint(showChats ? environment.theme.accent : VelagramTheme.elevatedSurface)
                        ForEach(TelegramCategory.allCases) { choice in
                            Button(choice.rawValue) { showChats = false; category = choice }
                                .buttonStyle(.borderedProminent).tint(!showChats && category == choice ? environment.theme.accent : VelagramTheme.elevatedSurface)
                                .accessibilityIdentifier("telegram.category.\(choice.rawValue)")
                        }
                    }.font(.subheadline).padding(.horizontal).padding(.vertical, 10)
                    if showChats { chatsList }
                    else { TelegramLibraryView(store: store, category: category) }
                }
                .navigationTitle("Telegram").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { account = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Telegram account") }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { downloads = true } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("Telegram downloads")
                        Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Open Telegram group")
                    }
                }
            } else { TelegramAuthView(store: store) }
        }
        .background(environment.theme.backgroundGradient)
        .task { await store.start() }
        .toolbar {
            if !store.ready { ToolbarItem(placement: .topBarTrailing) { Button("Downloads") { downloads = true } } }
        }
        .sheet(item: $resumeMedia) { media in NavigationStack { TelegramMediaDetailView(media: media, store: store) } }
        .sheet(isPresented: $adding) { NavigationStack { TelegramOpenChatView(store: store) } }
        .sheet(isPresented: $downloads) { NavigationStack { TelegramDownloadsView(store: store) } }
        .sheet(isPresented: $account) { NavigationStack { TelegramAccountView(store: store) } }
    }
    private var continueWatching: [TelegramMedia] {
        var series = Set<String>()
        return store.recentMedia.filter { media in
            guard let progress = VelagramStore.shared.progress["telegram:\(media.id)"], progress.position > 0,
                  progress.duration <= 0 || progress.position < progress.duration - 30 else { return false }
            return store.category(media) != .series || series.insert(media.seriesKey).inserted
        }
    }
    private var chatsList: some View {
        VStack(spacing: 0) {
            if !store.folders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("All chats") { folderID = nil; Task { await store.refreshChats() } }.buttonStyle(.bordered).tint(folderID == nil ? environment.theme.accent : .gray)
                        ForEach(store.folders) { folder in
                            Button(folder.title) { folderID = folder.id; Task { await store.refreshChats(folderID: folder.id) } }.buttonStyle(.bordered).tint(folderID == folder.id ? environment.theme.accent : .gray)
                        }
                    }.padding(.horizontal).padding(.bottom, 8)
                }
            }
            List {
                Section {
                    Label(store.status, systemImage: store.connected ? "checkmark.circle.fill" : "network").font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
                if store.isLoadingChats && visibleChats.isEmpty { ProgressView("Loading chats…") }
                if query.isEmpty && !continueWatching.isEmpty {
                    Section("Continue Watching") {
                        ForEach(continueWatching) { media in
                            Button { resumeMedia = media } label: { TelegramMediaRow(media: media, store: store) }.buttonStyle(.plain)
                        }
                    }
                }
                ForEach(visibleChats) { chat in
                    NavigationLink {
                        TelegramLibraryView(store: store, chatID: chat.id)
                            .navigationTitle(chat.title).navigationBarTitleDisplayMode(.inline)
                    } label: { TelegramChatRow(chat: chat, store: store) }
                        .contextMenu {
                            Button(store.pinned.contains(chat.id) ? "Unpin in Velagram" : "Pin in Velagram", systemImage: "pin") { store.togglePin(chat) }
                            Menu("Organize media as") {
                                ForEach(TelegramCategory.allCases) { category in
                                    Button(category == .all ? "Automatic" : category.rawValue) { store.mark(chat, as: category) }
                                }
                            }
                        }
                        .listRowBackground(VelagramTheme.surface)
                }
                if visibleChats.isEmpty && !store.isLoadingChats {
                    ContentUnavailableView(query.isEmpty ? "No chats yet" : "No matching chats", systemImage: "bubble.left.and.bubble.right", description: Text("Open one of your Telegram groups or search your chat titles."))
                }
                if store.hasMoreChats && query.isEmpty {
                    Button("Load more chats") { Task { await store.refreshChats(folderID: folderID, more: true) } }.disabled(store.isLoadingChats)
                }
                if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            }.scrollContentBackground(.hidden)
                .searchable(text: $query, prompt: "Search your chats")
                .task(id: query) {
                    guard !query.isEmpty else { return }
                    do { try await Task.sleep(for: .milliseconds(300)); searchedChats = try await store.searchChats(query) }
                    catch { if !Task.isCancelled { store.notice = error.localizedDescription } }
                }
                .refreshable { await store.refreshChats(folderID: folderID) }
        }
    }
}

struct TelegramChatRow: View {
    let chat: TelegramChat
    let store: TelegramStore
    var body: some View {
        HStack(spacing: 14) {
            TelegramThumbnail(fileID: chat.photoFileID, store: store, symbol: "person.2.fill").frame(width: 56, height: 56).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.title).font(.headline).foregroundStyle(.primary)
                Text(chat.kind == "chatTypePrivate" ? "Conversation" : chat.isForum ? "Group · Topics" : "Group or channel").font(.caption).foregroundStyle(.secondary)
            }
            if store.pinned.contains(chat.id) { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 5)
    }
}

struct TelegramThumbnail: View {
    let fileID: Int?
    let store: TelegramStore
    var symbol = "film.fill"
    var body: some View {
        ZStack {
            VelagramTheme.elevatedSurface
            if let id = fileID, let path = store.thumbnails[id], let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: symbol).font(.title2).foregroundStyle(.secondary) }
        }.clipped().task(id: fileID) { if let fileID { await store.loadThumbnail(fileID) } }
    }
}

struct TelegramLibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let store: TelegramStore
    var chatID: Int64?
    var category: TelegramCategory = .all
    @State private var browser: TelegramMediaBrowser
    @State private var localCategory: TelegramCategory = .all
    @State private var sort: TelegramSort = .newest
    @State private var query = ""
    @State private var topicID: Int64?
    @State private var selected: TelegramMedia?
    @State private var downloads = TelegramDownloads.shared
    private var activeCategory: TelegramCategory { chatID == nil ? category : localCategory }
    private var visible: [TelegramMedia] {
        TelegramClassification.sorted(browser.media.filter { activeCategory == .all || store.category($0) == activeCategory }, by: sort)
    }
    init(store: TelegramStore, chatID: Int64? = nil, category: TelegramCategory = .all) {
        self.store = store; self.chatID = chatID; self.category = category
        _browser = State(initialValue: TelegramMediaBrowser(store: store, chatID: chatID))
    }
    private var seriesGroups: [TelegramSeries] {
        let groups = TelegramSeries.group(visible)
        switch sort {
        case .newest: return groups.sorted { ($0.episodes.map(\.date).max() ?? .distantPast) > ($1.episodes.map(\.date).max() ?? .distantPast) }
        case .oldest: return groups.sorted { ($0.episodes.map(\.date).min() ?? .distantFuture) < ($1.episodes.map(\.date).min() ?? .distantFuture) }
        case .size: return groups.sorted { $0.episodes.reduce(Int64(0)) { $0 + $1.size } > $1.episodes.reduce(Int64(0)) { $0 + $1.size } }
        case .title, .episode: return groups
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if chatID != nil {
                Picker("Media type", selection: $localCategory) { ForEach(TelegramCategory.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal).padding(.top, 8)
            }
            HStack {
                if !browser.topics.isEmpty {
                    Picker("Topic", selection: $topicID) {
                        Text("All topics").tag(Int64?.none)
                        ForEach(browser.topics) { Text($0.title).tag(Optional($0.id)) }
                    }.labelsHidden()
                }
                Text("\(visible.count) files").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu { Picker("Sort", selection: $sort) { ForEach(TelegramSort.allCases) { Text($0.rawValue).tag($0) } } }
                label: { Label("Sort", systemImage: "arrow.up.arrow.down") }.font(.subheadline)
            }.padding(.horizontal).padding(.vertical, 10)
            List {
                if activeCategory == .series {
                    ForEach(seriesGroups) { series in
                        NavigationLink {
                            TelegramSeriesView(series: series, store: store)
                        } label: {
                            HStack(spacing: 14) {
                                TelegramThumbnail(fileID: series.episodes.first?.thumbnailFileID, store: store).frame(width: 70, height: 95).clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(series.title).font(.headline)
                                    Text("\(series.episodes.count) files · \(Set(series.episodes.compactMap { $0.episode?.season }).count) seasons").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.listRowBackground(VelagramTheme.surface)
                    }
                } else {
                    ForEach(visible) { media in
                        Button { selected = media } label: { TelegramMediaRow(media: media, store: store) }.buttonStyle(.plain)
                            .listRowBackground(VelagramTheme.surface)
                            .contextMenu { TelegramMediaActions(media: media, store: store) }
                    }
                }
                if let failure = browser.failure {
                    Text(failure).font(.callout).foregroundStyle(.orange)
                    Button("Retry") { Task { await browser.loadMore() } }
                }
                if browser.loading { ProgressView("Finding your media…") }
                if visible.isEmpty && !browser.loading && browser.failure == nil {
                    ContentUnavailableView("No \(activeCategory == .all ? "media" : activeCategory.rawValue.lowercased()) in loaded messages", systemImage: "film.stack", description: Text(browser.hasMore ? "Load more to search older messages. Files are grouped using their names and captions; you can change their category from the file menu." : "Try another topic, category, or search."))
                }
                if browser.hasMore {
                    Button("Load older media") { Task { await browser.loadMore() } }.disabled(browser.loading)
                }
            }.scrollContentBackground(.hidden)
        }
        .background(environment.theme.backgroundGradient)
        .searchable(text: $query, prompt: "Search filenames and captions")
        .task(id: query + ":\(topicID ?? 0)") {
            do { if !query.isEmpty { try await Task.sleep(for: .milliseconds(350)) }; try Task.checkCancellation(); await browser.reset(query: query, topicID: topicID) }
            catch { }
        }
        .task { await browser.loadTopics() }
        .refreshable { await browser.reset(query: query, topicID: topicID) }
        .sheet(item: $selected) { media in NavigationStack { TelegramMediaDetailView(media: media, store: store) } }
    }
}

struct TelegramMediaRow: View {
    let media: TelegramMedia
    let store: TelegramStore
    private var progress: DirectProgress? { VelagramStore.shared.progress["telegram:\(media.id)"] }
    var body: some View {
        HStack(spacing: 14) {
            TelegramThumbnail(fileID: media.thumbnailFileID, store: store, symbol: media.kind == .audio ? "music.note" : media.isVideo ? "film.fill" : "doc.fill")
                .frame(width: 76, height: 104).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) { if let progress, progress.duration > 0 { ProgressView(value: min(1, progress.position / progress.duration)).tint(.cyan).padding(5) } }
            VStack(alignment: .leading, spacing: 6) {
                Text(media.name).font(.headline).lineLimit(3).foregroundStyle(.primary)
                if let episode = media.episode { Text(String(format: "S%02d · E%02d", episode.season, episode.episode)).font(.caption.bold()).foregroundStyle(.cyan) }
                Text([media.size > 0 ? media.formattedSize : nil, media.date.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if let id = media.fileID, let file = store.files[id], file.downloading && file.size > 0 { ProgressView(value: Double(file.downloadedSize) / Double(file.size)).tint(.cyan) }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5).contentShape(Rectangle())
    }
}

struct TelegramSeriesView: View {
    let series: TelegramSeries
    let store: TelegramStore
    @State private var selected: TelegramMedia?
    private var seasons: [Int] { Set(series.episodes.map { $0.episode?.season ?? 0 }).sorted() }
    var body: some View {
        List {
            ForEach(seasons, id: \.self) { season in
                Section(season == 0 ? "Other files" : "Season \(season)") {
                    ForEach(series.episodes.filter { ($0.episode?.season ?? 0) == season }) { media in
                        Button { selected = media } label: { TelegramMediaRow(media: media, store: store) }.buttonStyle(.plain)
                            .contextMenu { TelegramMediaActions(media: media, store: store) }
                    }
                }
            }
        }.navigationTitle(series.title)
            .sheet(item: $selected) { media in NavigationStack { TelegramMediaDetailView(media: media, store: store, queue: series.episodes) } }
    }
}

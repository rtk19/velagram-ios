import SwiftUI

struct TelegramMediaActions: View {
    let media: TelegramMedia
    let store: TelegramStore
    var body: some View {
        Menu("Category") {
            ForEach(TelegramCategory.allCases) { category in
                Button(category == .all ? "Automatic" : category.rawValue) { store.mark(media, as: category) }
            }
        }
        if media.fileID != nil {
            Button("Download for offline use", systemImage: "arrow.down.circle") { TelegramDownloads.shared.begin(media, store: store) }
        }
    }
}

struct TelegramMediaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let media: TelegramMedia
    let store: TelegramStore
    var queue: [TelegramMedia] = []
    @State private var downloads = TelegramDownloads.shared
    @State private var playing = false
    @State private var notice: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TelegramThumbnail(fileID: media.thumbnailFileID, store: store).frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 18))
                Text(media.title).font(.title.bold())
                Text(media.name).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    if media.size > 0 { Label(media.formattedSize, systemImage: "internaldrive") }
                    if media.duration > 0 { Text(Duration.seconds(media.duration).formatted(.time(pattern: .minuteSecond))) }
                    Text(store.category(media).rawValue)
                }.font(.caption).foregroundStyle(.secondary)
                if media.isVideo || media.kind == .audio || media.kind == .link {
                    Button { playing = true } label: { Label(VelagramStore.shared.progress["telegram:\(media.id)"] == nil ? "Play" : "Resume", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(10) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("telegram.play")
                }
                if let url = downloads.local(media) {
                    let cached = downloads.saved.first { $0.id == media.id }?.isCached == true
                    Label(cached ? "Cached · available offline" : "Downloaded · available offline", systemImage: cached ? "internaldrive" : "checkmark.circle.fill").foregroundStyle(.green)
                    if cached { Button("Keep download", systemImage: "arrow.down.circle") { downloads.begin(media, store: store) } }
                    ShareLink(item: url) { Label("Share video file", systemImage: "square.and.arrow.up") }
                    if ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
                        Button("Import playlist into Live TV") {
                            do { try VelagramStore.shared.importText(String(contentsOf: url, encoding: .utf8)); notice = "Playlist imported into Live TV." }
                            catch { notice = error.localizedDescription }
                        }
                    }
                } else if let id = media.fileID {
                    if downloads.active[id] != nil {
                        let file = store.files[id]
                        if let progress = downloads.transferProgress["telegram:\(id)"] { DownloadTransferProgressView(progress: progress) }
                        else { ProgressView(value: file.map { $0.size > 0 ? Double($0.downloadedSize) / Double($0.size) : 0 } ?? 0) }
                        ConfirmCancelDownloadButton { downloads.cancel(id, store: store) }
                    } else {
                        Button("Download for offline use", systemImage: "arrow.down.circle") { downloads.begin(media, store: store) }
                    }
                    if let error = downloads.errors[id] { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                Menu("Organize as \(store.category(media).rawValue)") {
                    ForEach(TelegramCategory.allCases) { category in Button(category == .all ? "Automatic" : category.rawValue) { store.mark(media, as: category) } }
                }
                if !media.caption.isEmpty { Text(media.caption).textSelection(.enabled) }
                if let chat = store.chats[media.chatID] { Label(chat.title, systemImage: "bubble.left.and.bubble.right").font(.caption).foregroundStyle(.secondary) }
                Text(media.date.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                if let notice { Text(notice).font(.caption) }
            }.padding(20)
        }
        .navigationTitle("Telegram file").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .fullScreenCover(isPresented: $playing) { TelegramPlayerView(media: media, store: store, queue: queue) }
    }
}

/// A title appears once; episodes and releases live inside that title.
struct DownloadsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    var store: TelegramStore = .shared
    @State private var downloads = TelegramDownloads.shared
    @State private var query = ""
    @State private var scope = "All"
    private var reloadOnAppear = true
    init(store: TelegramStore = .shared, downloads: TelegramDownloads = .shared, reloadOnAppear: Bool = true) {
        self.store = store; _downloads = State(initialValue: downloads); self.reloadOnAppear = reloadOnAppear
    }
    private var titles: [OfflineLibraryTitle] {
        let sources = downloads.sources().filter { source in
            let matchesScope = scope == "All" || (scope == "Partial" ? source.record == nil : scope == "Cached" ? source.record?.isCached == true && source.transferID == nil : source.record?.isCached == false || source.transferID != nil)
            return matchesScope && (scope != "All" || source.record != nil || source.transferID != nil) && (query.isEmpty || (source.request?.displayTitle ?? source.media.name).localizedStandardContains(query))
        }
        return OfflineLibraryIndex.titles(sources)
    }
    private var partialTitles: [OfflineLibraryTitle] {
        OfflineLibraryIndex.titles(downloads.sources().filter {
            $0.record == nil && $0.transferID == nil && (query.isEmpty || ($0.request?.displayTitle ?? $0.media.name).localizedStandardContains(query))
        })
    }
    private func titleLink(_ title: OfflineLibraryTitle) -> some View {
        NavigationLink {
            if title.media.kind == .movie, let content = title.contents.first {
                OfflineDownloadSourcesView(titleID: title.id, contentID: content.id, downloads: downloads, store: store)
            } else { OfflineDownloadEpisodesView(titleID: title.id, downloads: downloads, store: store) }
        } label: { OfflineTitleNavigationRow(title: title, downloads: downloads) }
        .buttonStyle(.plain).accessibilityIdentifier("downloads.title." + title.id)
    }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                Picker("Show", selection: $scope) {
                    ForEach(["All", "Downloaded", "Cached", "Partial"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).padding(.bottom, 8)
                if titles.isEmpty && (scope != "All" || partialTitles.isEmpty) {
                    ContentUnavailableView("Your offline library", systemImage: "arrow.down.circle", description: Text(query.isEmpty ? "Download a source from the scanner. Fully cached videos also appear here." : "No offline titles match your search."))
                }
                if scope == "Partial", !titles.isEmpty { Text("Partially downloaded").font(.headline).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(titles) { title in titleLink(title) }
                if scope == "All", !partialTitles.isEmpty {
                    Text("Partially downloaded").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                    ForEach(partialTitles) { title in titleLink(title) }
                }
                ForEach(downloads.errors.keys.sorted(), id: \.self) { id in
                    Text(downloads.errors[id] ?? "").font(.caption).foregroundStyle(.orange)
                }
                ForEach(downloads.webErrors.keys.sorted(), id: \.self) { id in
                    Text(downloads.webErrors[id] ?? "").font(.caption).foregroundStyle(.orange)
                }
            }.padding(.horizontal, 20).padding(.vertical, 8)
        }
        .background(environment.theme.backgroundGradient)
        .searchable(text: $query, prompt: "Search offline titles")
        .navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: store.ready) {
            if reloadOnAppear { downloads.reload(); await downloads.refreshCached(store: store) }
        }
    }
}

private func offlineSourceCount(_ count: Int) -> String { "\(count) " + (count == 1 ? "source" : "sources") }

/// The library's root describes a collection, never an arbitrary watched episode.
private struct OfflineTitleNavigationRow: View {
    let title: OfflineLibraryTitle
    let downloads: TelegramDownloads
    private var artworkURL: URL? { title.contents.flatMap(\.sources).compactMap { $0.record?.titleArtworkURL }.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Group {
                    if let artworkURL, let image = UIImage(contentsOfFile: artworkURL.path) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        CachedRemoteImage(url: title.media.backdropURL) { $0.resizable().scaledToFill() } placeholder: {
                            Rectangle().fill(.gray.opacity(0.22)).overlay { Image(systemName: title.media.kind == .series ? "tv" : "film") }
                        }
                    }
                }.frame(width: 128, height: 74).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title.media.title).font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                    Text(title.availabilityLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 24)
            }
            ForEach(title.activeContents) { content in
                if let progress = DownloadTransferProgress.combined(content.sources.compactMap { $0.transferID.flatMap { downloads.transferProgress[$0] } }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label(activityLabel(content), systemImage: "arrow.down.circle").font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        DownloadTransferProgressView(progress: progress)
                    }
                }
            }
        }.padding(12).velagramSurface(cornerRadius: 16).contentShape(Rectangle())
    }
    private func activityLabel(_ content: OfflineLibraryContent) -> String {
        let count = content.sources.filter { $0.transferID != nil }.count
        let suffix = count > 1 ? " · \(count) sources" : ""
        guard let episode = content.request.episode else { return "Downloading movie" + suffix }
        let code = String(format: "S%02dE%02d", episode.seasonNumber, episode.number)
        return "Downloading " + code + (episode.title.map { " · " + $0 } ?? "") + suffix
    }
}

private struct OfflineNavigationRow: View {
    @EnvironmentObject private var library: LibraryStore
    let content: OfflineLibraryContent
    let downloads: TelegramDownloads
    let detail: String
    var transferIDs: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ContinueWatchingRowContent(progress: content.progress(in: library), localArtworkURL: content.artworkURL, detail: detail)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 24)
            }
            if let progress = DownloadTransferProgress.combined(transferIDs.compactMap { downloads.transferProgress[$0] }) {
                DownloadTransferProgressView(progress: progress)
            }
        }.padding(12).velagramSurface(cornerRadius: 16).contentShape(Rectangle())
    }
}

private struct OfflineDownloadEpisodesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let titleID: String
    let downloads: TelegramDownloads
    let store: TelegramStore
    private var title: OfflineLibraryTitle? { OfflineLibraryIndex.titles(downloads.sources()).first { $0.id == titleID } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let title {
                    ForEach(Array(Set(title.contents.compactMap { $0.request.episode?.seasonNumber })).sorted(), id: \.self) { season in
                        Text("Season \(season)").font(.headline).padding(.top, 12).padding(.bottom, 4)
                        ForEach(title.contents.filter { $0.request.episode?.seasonNumber == season }) { content in
                            NavigationLink {
                                OfflineDownloadSourcesView(titleID: titleID, contentID: content.id, downloads: downloads, store: store)
                            } label: {
                                OfflineNavigationRow(content: content, downloads: downloads, detail: offlineSourceCount(content.sources.count), transferIDs: content.sources.compactMap(\.transferID))
                            }.buttonStyle(.plain).accessibilityIdentifier("downloads.episode." + content.id)
                        }
                    }
                } else { ContentUnavailableView("No offline episodes", systemImage: "tv") }
            }.padding(.horizontal, 20).padding(.vertical, 8)
        }.background(environment.theme.backgroundGradient)
            .navigationTitle(title?.media.title ?? "Episodes").navigationBarTitleDisplayMode(.inline)
    }
}

private struct OfflineDownloadSourcesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    let titleID: String
    let contentID: String
    let downloads: TelegramDownloads
    let store: TelegramStore
    @State private var selection: TelegramSavedDownload?
    @State private var fileSelection: TelegramMedia?
    @State private var removal: TelegramMedia?
    @State private var failure: String?
    private var content: OfflineLibraryContent? {
        OfflineLibraryIndex.titles(downloads.sources()).first { $0.id == titleID }?.contents.first { $0.id == contentID }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let content {
                    ContinueWatchingRowContent(progress: content.progress(in: library), localArtworkURL: content.artworkURL)
                        .padding(12).velagramSurface(cornerRadius: 16)
                    Text("Sources · \(content.sources.count)").font(.headline).padding(.top, 8)
                    ForEach(content.sources) { source in sourceRow(source) }
                } else { ContentUnavailableView("No offline sources", systemImage: "arrow.down.circle") }
            }.padding(.horizontal, 20).padding(.vertical, 8)
        }
        .background(environment.theme.backgroundGradient)
        .navigationTitle(content?.request.episode.map { "S\($0.seasonNumber) E\($0.number)" } ?? content?.request.media.title ?? "Sources")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove downloaded source?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove download", role: .destructive) {
                if let media = removal {
                    Task { do { try await downloads.deleteSource(media, store: store) } catch { failure = error.localizedDescription } }
                }
                removal = nil
            }
        } message: { Text("Watch history and other sources are kept.") }
        .alert("Downloads", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
        .sheet(item: $fileSelection) { media in NavigationStack { TelegramMediaDetailView(media: media, store: store) } }
        .fullScreenCover(item: $selection) { item in
            let request = item.request ?? content?.request
            TelegramPlayerView(media: item.media, store: store, catalogRequest: request, library: library,
                nextCatalogRequest: request.flatMap { downloads.nextAvailable(after: $0, library: library) })
        }
    }
    private func sourceRow(_ source: OfflineLibrarySource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                guard let record = source.record else { return }
                if record.media.isVideo || record.media.kind == .audio { selection = record }
                else { fileSelection = record.media }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: source.record == nil ? "arrow.down.circle" : "play.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.media.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        Text(source.provider).font(.caption).foregroundStyle(.secondary)
                        if source.record != nil { Label(source.record?.isCached == true ? "Cached" : "Downloaded", systemImage: source.record?.isCached == true ? "internaldrive" : "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(source.record == nil)
            if let key = source.transferID {
                DownloadTransferProgressView(progress: downloads.transferProgress[key] ?? DownloadTransferProgress(received: 0, total: source.media.size, bytesPerSecond: 0, sampledAt: ProcessInfo.processInfo.systemUptime))
                ConfirmCancelDownloadButton { downloads.cancelTransfer(key, store: store) }
            } else if source.record == nil, let id = source.media.fileID, let file = downloads.partialFiles[id] {
                Label("Partially downloaded", systemImage: "internaldrive").font(.caption)
                ProgressView(value: Double(min(file.downloadedSize, file.size)), total: Double(max(1, file.size)))
                Text(ByteCountFormatter.string(fromByteCount: file.downloadedSize, countStyle: .file) + " on device").font(.caption).foregroundStyle(.secondary)
                Button("Resume download", systemImage: "arrow.down.circle") { downloads.begin(source.media, store: store) }
                Button("Delete download", systemImage: "trash", role: .destructive) {
                    removal = source.media
                }
            } else if let record = source.record {
                Text(record.media.formattedSize).font(.caption).foregroundStyle(.secondary)
                if record.isCached {
                    Button("Keep download", systemImage: "arrow.down.circle") { downloads.begin(record.media, store: store) }
                } else { Button("Remove download", systemImage: "trash", role: .destructive) { removal = record.media } }
            }
            if let id = source.media.fileID, let error = downloads.errors[id] { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(14).velagramSurface(cornerRadius: 16).accessibilityIdentifier("downloads.source." + source.id)
    }
}

struct DownloadTransferProgressView: View {
    let progress: DownloadTransferProgress
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(progress.percentage).fontWeight(.semibold)
                    Spacer()
                    Text(progress.speedLabel(now: ProcessInfo.processInfo.systemUptime))
                }
                .font(.caption).monospacedDigit()
                ProgressView(value: progress.fraction)
                Text(progress.sizeLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.accessibilityElement(children: .combine)
        }
    }
}

struct TelegramOpenChatView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TelegramStore
    @State private var address = ""
    @State private var chat: TelegramChat?
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        Form {
            Section {
                TextField("@username or https://t.me/…", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Open group or channel") { run(join: false) }.disabled(address.isEmpty || busy)
                if address.contains("t.me/+") || address.contains("joinchat/") {
                    Button("Join group using this invitation") { run(join: true) }.disabled(busy)
                    Text("Joining changes your Telegram group membership. Telegram may require administrator approval.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if busy { ProgressView() }
            if let failure { Text(failure).foregroundStyle(.orange) }
            if let chat { NavigationLink { TelegramLibraryView(store: store, chatID: chat.id).navigationTitle(chat.title) } label: { TelegramChatRow(chat: chat, store: store) } }
        }.navigationTitle("Open Telegram group")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private func run(join: Bool) {
        Task {
            busy = true; failure = nil; defer { busy = false }
            do { chat = try await (join ? store.join(address) : store.openPublicChat(address)) }
            catch { failure = error.localizedDescription }
        }
    }
}

struct TelegramAccountView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TelegramStore
    @State private var name = ""
    @State private var confirmingLogout = false
    var body: some View {
        Form {
            Section("Account") {
                if !name.isEmpty { LabeledContent("Signed in as", value: name) }
                LabeledContent("Connection", value: store.status)
                Text("Telegram login data is encrypted on this device and excluded from exported Velagram backups. Saved downloads and your organization preferences are included.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Sign out of Telegram", role: .destructive) { confirmingLogout = true }
            }
        }.navigationTitle("Telegram account")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of Telegram on this device?", isPresented: $confirmingLogout, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await store.logOut(); dismiss() } }
            }
            .task {
                if let user = try? await store.transport.call("getMe") { name = [user["first_name"].string, user["last_name"].string].compactMap { $0 }.joined(separator: " ") }
            }
    }
}

/// Cancellation is destructive to transfer progress, so every stop control asks first.
struct ConfirmCancelDownloadButton: View {
    let action: () -> Void
    @State private var confirming = false
    var body: some View {
        Button("Cancel download") { confirming = true }
            .alert("Cancel this download?", isPresented: $confirming) {
                Button("Cancel download", role: .destructive, action: action)
                Button("Keep downloading", role: .cancel) {}
            }
    }
}

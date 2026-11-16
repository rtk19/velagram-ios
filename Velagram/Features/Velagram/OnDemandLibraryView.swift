import SwiftUI

struct IPTVSourcePlayerView: View {
    let stream: PlayableStream
    var request: PlaybackRequest? = nil
    var library: LibraryStore? = nil
    var nextRequest: PlaybackRequest? = nil
    @State private var continuedStream: PlayableStream?
    var body: some View {
        let stream = continuedStream ?? self.stream
        let name = stream.candidate.preference.serverName + "." + (stream.source.url.pathExtension.isEmpty ? "m3u8" : stream.source.url.pathExtension)
        let media = TelegramMedia(chatID: 0, messageID: 0, fileID: nil, name: name, caption: "", date: .now, size: 0, duration: Int(stream.catchupReplay?.catchupContext?.duration ?? 0), mimeType: "video/" + stream.source.url.pathExtension, thumbnailFileID: nil, kind: .video, remoteURL: stream.source.url)
        TelegramPlayerView(media: media, store: .shared, catalogRequest: request, library: library, rememberPlayback: true, headers: stream.source.headers, sourceHistoryID: "web:" + stream.candidate.id, nextCatalogRequest: nextRequest,
                           catchup: stream.catchupReplay, resumePlayback: continuedStream == nil, onPlaybackEnded: {
            guard let replay = stream.catchupReplay, let next = VelagramStore.shared.nextCatchup(after: replay) else { return }
            continuedStream = OnDemandLibraryView.playable(next)
        }).id(stream.id)
    }
}

struct OnDemandLibraryView: View {
    @State private var store = VelagramStore.shared
    @State private var query = ""
    @State private var selected: PlayableStream?
    @State private var category = "All"
    private var categories: [String] { ["All"] + store.sortedCategories(Set(store.visibleChannels.filter { $0.contentKind != nil }.map(\.group) + store.visibleSeries.compactMap(\.group))) }
    var body: some View {
        List {
            IPTVLoadingStatus()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(categories, id: \.self) { item in
                        Button { category = item } label: { Label(item, systemImage: store.favoriteCategories.contains(item) ? "pin.fill" : "folder") }
                            .buttonStyle(.borderedProminent).tint(category == item ? .purple : .gray)
                            .contextMenu { if item != "All" { CategoryActions(category: item, onHide: { category = "All" }) } }
                    }
                }
            }
            NavigationLink("Hidden categories") { HiddenIPTVSourcesView() }
            Section("Movies & imported episodes") {
                ForEach(store.visibleChannels.filter { $0.contentKind != nil && (category == "All" || $0.group == category) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { entry in
                    Button { selected = Self.playable(entry) } label: {
                        HStack(spacing: 12) {
                            ChannelArtwork(channel: entry).frame(width: 56, height: 80)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).font(.headline)
                                Text(entry.group).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            Section("Xtream series") {
                ForEach(store.visibleSeries.filter { (category == "All" || $0.group == category) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { show in
                    NavigationLink { IPTVSeriesView(show: show) } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: show.cover) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "tv") }
                                .frame(width: 56, height: 80)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(show.name).font(.headline)
                                Text(show.group ?? "Series").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if store.channels.allSatisfy({ $0.contentKind == nil }), store.iptvSeries.isEmpty {
                Text("Connect a playlist or Xtream account in Playlists & Xtream. Its on-demand titles also appear in catalog source scans.").foregroundStyle(.secondary)
            }
        }.navigationTitle("IPTV on demand").searchable(text: $query)
            .fullScreenCover(item: $selected) { IPTVSourcePlayerView(stream: $0) }
    }
    static func playable(_ entry: LiveChannel) -> PlayableStream {
        let source = PlaybackSource(url: entry.url, headers: entry.headers, subtitles: [], preferredPeakBitRate: nil)
        let candidate = PlaybackCandidate(id: "iptv:" + entry.id, preference: .init(providerID: "iptv", serverName: entry.name, audioLanguage: ""), providerName: entry.group, subtitleKind: .selectable) { source }
        return PlayableStream(candidate: candidate, source: source, qualities: [], catchupReplay: entry.catchupContext == nil ? nil : entry)
    }
}

private struct IPTVSeriesView: View {
    let show: IPTVSeries
    @State private var store = VelagramStore.shared
    @State private var episodes: [LiveChannel] = []
    @State private var failure: String?
    @State private var loading = true
    @State private var selected: PlayableStream?
    var body: some View {
        List {
            if loading { ProgressView("Loading episodes…") }
            if let failure { Text(failure) }
            ForEach(episodes) { entry in Button(entry.name) { selected = OnDemandLibraryView.playable(entry) } }
        }.navigationTitle(show.name)
            .task {
                defer { loading = false }
                let provider = store.iptvProvider()
                guard let account = provider.accounts.first(where: { $0.id == show.accountID }), let login = provider.credentials[account.id] else { failure = "Reconnect this Xtream account to load episodes."; return }
                do { episodes = try await IPTVOnDemandClient(account: account, credentials: login).allEpisodes(show) }
                catch { failure = "Episodes could not be loaded. Check this account's connection." }
            }
            .fullScreenCover(item: $selected) { IPTVSourcePlayerView(stream: $0) }
    }
}

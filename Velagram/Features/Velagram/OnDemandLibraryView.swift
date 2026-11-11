import SwiftUI

struct IPTVSourcePlayerView: View {
    let stream: PlayableStream
    var request: PlaybackRequest? = nil
    var library: LibraryStore? = nil
    var nextRequest: PlaybackRequest? = nil
    var body: some View {
        let name = stream.candidate.preference.serverName + "." + (stream.source.url.pathExtension.isEmpty ? "m3u8" : stream.source.url.pathExtension)
        let media = TelegramMedia(chatID: 0, messageID: 0, fileID: nil, name: name, caption: "", date: .now, size: 0, duration: 0, mimeType: "video/" + stream.source.url.pathExtension, thumbnailFileID: nil, kind: .video, remoteURL: stream.source.url)
        TelegramPlayerView(media: media, store: .shared, catalogRequest: request, library: library, rememberPlayback: true, headers: stream.source.headers, nextCatalogRequest: nextRequest)
    }
}

struct OnDemandLibraryView: View {
    @State private var store = VelagramStore.shared
    @State private var query = ""
    @State private var selected: PlayableStream?
    var body: some View {
        List {
            Section("Movies & imported episodes") {
                ForEach(store.channels.filter { $0.contentKind != nil && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { entry in
                    Button(entry.name) { selected = Self.playable(entry) }
                }
            }
            Section("Xtream series") {
                ForEach(store.iptvSeries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { show in
                    NavigationLink(show.name) { IPTVSeriesView(show: show) }
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
        return PlayableStream(candidate: candidate, source: source, qualities: [])
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

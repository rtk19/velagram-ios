import SwiftUI
import UniformTypeIdentifiers

struct MoreView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var store = VelagramStore.shared
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "play.square.stack.fill").font(.largeTitle).foregroundStyle(environment.theme.accentBright)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Velagram").font(.largeTitle.bold())
                        Text("A world of entertainment. In your pocket.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 12)
            }.listRowBackground(VelagramTheme.surface)
            Section("Explore") {
                NavigationLink { TelegramRootView() } label: { Label("Telegram account & files", systemImage: "paperplane.fill") }
                NavigationLink { CatalogView(kind: .series) } label: { Label("Series", systemImage: "tv.fill") }
                NavigationLink { LiveView(radioOnly: true) } label: { Label("Radio & music", systemImage: "radio.fill") }
                NavigationLink { MediaServersView() } label: { Label("Jellyfin & Emby", systemImage: "server.rack") }
                NavigationLink { LocalMediaView() } label: { Label("Files & direct streams", systemImage: "folder.fill") }
                NavigationLink { ProgramGuideView() } label: { Label("Program guide", systemImage: "calendar") }
            }.listRowBackground(VelagramTheme.surface)
            Section("Your space") {
                NavigationLink { LiveFavoritesView() } label: { Label("Favorite channels", systemImage: "star.fill") }
                NavigationLink { OnDemandLibraryView() } label: { Label("IPTV movies & episodes", systemImage: "film.stack") }
                NavigationLink { PlaylistImportView() } label: { Label("Playlists & Xtream", systemImage: "list.bullet.rectangle") }
                NavigationLink { ProfilesView() } label: { Label("Live TV profiles", systemImage: "person.2.fill") }
                NavigationLink { AddonSettingsView() } label: { Label("Stream add-on", systemImage: "puzzlepiece.extension.fill") }
                NavigationLink { SettingsView() } label: { Label("Settings & backup", systemImage: "gearshape.fill") }
            }.listRowBackground(VelagramTheme.surface)
            Section {
                Text("Velagram for iPhone & iPad").font(.footnote).foregroundStyle(.secondary)
                Text("Built on Vela’s native interface and player.").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(VelagramTheme.surface)
        }.scrollContentBackground(.hidden).background(environment.theme.backgroundGradient)
            .navigationTitle("More")
    }
}

struct LiveFavoritesView: View {
    @State private var store = VelagramStore.shared
    @State private var selection: LiveChannel?
    var body: some View {
        List {
            let favorites = (BundledChannels.load() + store.channels).filter { store.favorites.contains($0.id) }
            if favorites.isEmpty { ContentUnavailableView("Your favorites live here", systemImage: "star", description: Text("Tap the star beside any TV or radio channel to save it.")) }
            ForEach(favorites) { channel in
                Button { selection = channel } label: { HStack { ChannelArtwork(channel: channel).frame(width: 64, height: 44); Text(channel.name); Spacer(); Image(systemName: "play.fill") } }.buttonStyle(.plain)
            }
        }.navigationTitle("Favorites").fullScreenCover(item: $selection) { DirectPlayerView(channel: $0) }
    }
}

struct ProfilesView: View {
    @State private var store = VelagramStore.shared
    @State private var name = ""
    var body: some View {
        Form {
            Section {
                ForEach(store.profiles) { profile in
                    Button { store.switchProfile(profile) } label: {
                        HStack { Image(systemName: profile.symbol); Text(profile.name); Spacer(); if store.activeProfile == profile.id { Image(systemName: "checkmark.circle.fill") } }
                    }
                }
            } header: { Text("Live TV profiles") } footer: { Text("Each profile has its own imported channels, favorites, recent streams, media servers, and stream playback positions. The movie and series catalog uses the shared Vela library.") }
            Section("New profile") {
                TextField("Name", text: $name)
                Button("Create profile") { store.addProfile(name); name = "" }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.navigationTitle("Profiles")
    }
}

struct AddonSettingsView: View {
    @AppStorage("velagram.addon.manifest") private var manifest = ""
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                TextField("https://…/manifest.json", text: $manifest).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Validate manifest") {
                    Task {
                        do {
                            let url = try VelagramHTTP.url(manifest)
                            let data = try await VelagramHTTP().data(url)
                            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                            guard let name = object?["name"] as? String, object?["resources"] != nil else { throw VelagramNetworkError.invalidResponse }
                            message = "Connected to \(name). HTTP streams will appear in title source searches."
                        } catch { message = error.localizedDescription }
                    }
                }
            } header: { Text("Stremio-compatible stream add-on") } footer: { Text("Use your own manifest URL. Supports HTTP HLS, MP4, MOV and subtitle resources. Torrent and magnet sources require a separate iOS-compatible resolver.") }
            if let message { Text(message) }
        }.navigationTitle("Stream add-on")
    }
}

struct LocalMediaView: View {
    @State private var picking = false
    @State private var address = ""
    @State private var title = ""
    @State private var selection: LiveChannel?
    @State private var error: String?
    @State private var store = VelagramStore.shared
    var body: some View {
        Form {
            Section("Open a stream") {
                TextField("Title (optional)", text: $title)
                TextField("https://…", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Play stream", systemImage: "play.fill") {
                    do { let url = try VelagramHTTP.url(address); selection = LiveChannel(id: LiveChannel.identity(url.absoluteString), name: title.isEmpty ? url.lastPathComponent : title, url: url, group: "Direct streams") }
                    catch { self.error = error.localizedDescription }
                }.disabled(address.isEmpty)
            }
            Section {
                Button("Open video or audio file", systemImage: "folder") { picking = true }
            } footer: { Text("Files are copied into Velagram for reliable playback and backup. Playback supports formats available to Apple’s native player, including MP4, MOV, HLS and common audio formats.") }
            Section("Recent files & streams") {
                ForEach(store.recent.filter { $0.group == "Files" || $0.group == "Direct streams" }) { channel in
                    Button(channel.name) { selection = channel }
                        .contextMenu { Button("Remove from Recently Played", systemImage: "trash", role: .destructive) { store.removeRecent(channel) } }
                        .swipeActions { Button("Remove", role: .destructive) { store.removeRecent(channel) } }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Files & streams")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.movie, .audio]) { result in
                do {
                    let source = try result.get(); let access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Velagram/Files")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let destination = root.appending(path: UUID().uuidString + "." + source.pathExtension)
                    try FileManager.default.copyItem(at: source, to: destination)
                    selection = LiveChannel(id: "file:\(destination.lastPathComponent)", name: source.deletingPathExtension().lastPathComponent, url: destination, group: "Files")
                } catch { self.error = error.localizedDescription }
            }
            .fullScreenCover(item: $selection) { DirectPlayerView(channel: $0) }
    }
}

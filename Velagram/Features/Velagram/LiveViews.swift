import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct LiveView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var store = VelagramStore.shared
    @State private var query = ""
    @State private var group = "All"
    @State private var favoritesOnly = false
    @State private var showImport = false
    @State private var selection: LiveChannel?
    var radioOnly = false

    private var allChannels: [LiveChannel] { (BundledChannels.load() + store.channels).filter { $0.isRadio == radioOnly && $0.contentKind == nil } }
    private var groups: [String] { ["All"] + Set(allChannels.map(\.group)).sorted() }
    private var filtered: [LiveChannel] {
        allChannels.filter { channel in
            (group == "All" || channel.group == group) && (!favoritesOnly || store.favorites.contains(channel.id)) &&
            (query.isEmpty || channel.name.localizedCaseInsensitiveContains(query) || channel.group.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(radioOnly ? "YOUR DAILY SOUNDTRACK" : "ON AIR, RIGHT NOW")
                        .font(.caption.weight(.bold)).tracking(2).foregroundStyle(environment.theme.accentBright)
                    Text(radioOnly ? "Radio & music" : "Live television").font(.largeTitle.bold())
                    Text(radioOnly ? "Stations from home. Wherever you are." : "Your channels, together in one place.")
                        .foregroundStyle(.secondary)
                }.padding(.top, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button { favoritesOnly.toggle() } label: {
                            Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star")
                        }.buttonStyle(.bordered).tint(favoritesOnly ? environment.theme.accent : .gray)
                        ForEach(groups, id: \.self) { item in
                            Button(item) { group = item }.buttonStyle(.borderedProminent)
                                .tint(group == item ? environment.theme.accent : VelagramTheme.elevatedSurface)
                        }
                    }
                }
                if !store.recent.filter({ $0.isRadio == radioOnly && $0.contentKind == nil }).isEmpty && query.isEmpty && !favoritesOnly {
                    Text("Recently played").font(.title3.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(store.recent.filter { $0.isRadio == radioOnly && $0.contentKind == nil }.prefix(8)) { channel in
                                Button { selection = channel } label: {
                                    VStack { ChannelArtwork(channel: channel).frame(width: 96, height: 64)
                                        Text(channel.name).font(.caption).lineLimit(1).frame(width: 100) }
                                    .padding(10).background(VelagramTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain)
                                .contextMenu { Button("Remove from Recently Played", systemImage: "trash", role: .destructive) { store.removeRecent(channel) } }
                            }
                        }
                    }
                }
                HStack { Text("\(filtered.count) channels").font(.headline); Spacer()
                    NavigationLink { ProgramGuideView() } label: { Label("Guide", systemImage: "list.bullet.rectangle") }
                }
                if filtered.isEmpty {
                    ContentUnavailableView("Make it yours", systemImage: "tv.badge.plus", description: Text("Import an M3U playlist or connect an Xtream account to add your channels."))
                    Button("Add channels") { showImport = true }.buttonStyle(.borderedProminent)
                }
                ForEach(filtered) { channel in
                    HStack(spacing: 14) {
                        Button { selection = channel } label: {
                            HStack(spacing: 14) {
                                ChannelArtwork(channel: channel).frame(width: 76, height: 56)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(channel.name).font(.headline).foregroundStyle(.primary)
                                    Text(store.schedule(channel).first?.title ?? channel.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(environment.theme.accentBright)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { store.toggleFavorite(channel) } label: {
                            Image(systemName: store.favorites.contains(channel.id) ? "star.fill" : "star").padding(8)
                        }.accessibilityLabel("Favorite \(channel.name)")
                    }
                    .padding(12).background(VelagramTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(environment.theme.backgroundGradient)
        .navigationTitle(radioOnly ? "Radio" : "Live").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find a channel")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showImport = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add playlist") } }
        .sheet(isPresented: $showImport) { NavigationStack { PlaylistImportView() } }
        .fullScreenCover(item: $selection) { DirectPlayerView(channel: $0) }
        .task { await store.refreshGuide() }
    }
}

struct ChannelArtwork: View {
    let channel: LiveChannel
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
            if let name = channel.bundledImage, let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit().padding(5)
            } else if let logo = channel.logo {
                AsyncImage(url: logo) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: channel.isRadio ? "radio" : "tv") }.padding(6)
            } else { Image(systemName: channel.isRadio ? "radio" : "tv").font(.title2).foregroundStyle(.secondary) }
        }.clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}

struct PlaylistImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = VelagramStore.shared
    @State private var mode = "M3U"
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var picking = false
    var body: some View {
        Form {
            Section {
                Picker("Connection", selection: $mode) { Text("M3U playlist").tag("M3U"); Text("Xtream Codes").tag("Xtream") }.pickerStyle(.segmented)
                TextField(mode == "M3U" ? "http:// or https:// playlist URL" : "http:// or https:// server URL", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                if mode == "Xtream" {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Button {
                    Task {
                        do {
                            let base = try VelagramHTTP.url(address)
                            if mode == "Xtream" {
                                await store.importXtream(server: base, username: username, password: password)
                            } else { await store.importPlaylist(base) }
                        } catch { store.notice = error.localizedDescription }
                    }
                } label: { if store.busy { ProgressView() } else { Label("Connect", systemImage: "link") } }.disabled(store.busy || address.isEmpty)
                Button("Import M3U file") { picking = true }
            } footer: { Text("Live channels and on-demand movies/episodes are merged with your library and included in source searches. HTTP and HTTPS addresses are supported. Reimporting updates existing streams without duplicating them.") }
            Section("Program guide") {
                TextField("XMLTV guide URL", text: $store.guideURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Save and refresh guide") { store.persist(); Task { await store.refreshGuide() } }
            }
            if !store.channels.isEmpty {
                Section("Imported channels") {
                    ForEach(store.channels) { channel in Text(channel.name) }
                        .onDelete { store.channels.remove(atOffsets: $0); store.persist() }
                }
            }
        }
        .navigationTitle("Add channels")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.persist(); dismiss() } } }
        .alert("Velagram", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) { Button("OK") { store.notice = nil } } message: { Text(store.notice ?? "") }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try store.importText(String(contentsOf: url, encoding: .utf8))
            } catch { store.notice = error.localizedDescription }
        }
    }
}

struct ProgramGuideView: View {
    @State private var store = VelagramStore.shared
    @State private var query = ""
    var body: some View {
        List {
            if store.programs.isEmpty {
                ContentUnavailableView("Add a program guide", systemImage: "calendar", description: Text("Set an XMLTV URL in Add channels, then refresh. Programs use your device’s local time."))
            }
            ForEach((BundledChannels.load() + store.channels).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { channel in
                let programs = store.schedule(channel)
                if !programs.isEmpty {
                    Section(channel.name) {
                        ForEach(programs.prefix(24)) { program in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(program.title).font(.headline)
                                Text("\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                if !program.summary.isEmpty { Text(program.summary).font(.caption).lineLimit(3) }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("Program guide").searchable(text: $query)
            .refreshable { await store.refreshGuide() }.task { await store.refreshGuide() }
    }
}

import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct LiveView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var store = VelagramStore.shared
    @State private var query = ""
    @State private var showImport = false
    @State private var showEditor = false
    var radioOnly = false
    private var allCategoryNames: Set<String> {
        Set((BundledChannels.load() + store.channels).filter { $0.contentKind == nil && $0.isRadio == radioOnly }.map(\.group))
    }
    private var grouped: [String: [LiveChannel]] { Dictionary(grouping: store.liveChannels.filter { $0.isRadio == radioOnly }, by: \.group) }
    var body: some View {
        let channels = grouped
        let categories = store.sortedCategories(Set(channels.keys)).filter { category in
            query.isEmpty || category.localizedCaseInsensitiveContains(query)
        }
        Group {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        List {
            Section {
                Text(radioOnly ? "Radio & music" : "Live TV").font(.largeTitle.bold())
                Text("Choose a category to browse channels and what’s on.").foregroundStyle(.secondary)
                IPTVLoadingStatus()
            }.listRowBackground(Color.clear)
            Section {
                NavigationLink { LiveChannelListView(radioOnly: radioOnly) } label: {
                    Label("All channels", systemImage: "square.grid.2x2")
                }
                NavigationLink { LiveChannelListView(radioOnly: radioOnly, favoritesOnly: true) } label: {
                    Label("Favorite channels", systemImage: "star.fill")
                }
                NavigationLink { ProgramGuideView(lineup: store.liveChannels.filter { $0.isRadio == radioOnly }) } label: { Label("Program guide", systemImage: "list.bullet.rectangle") }
            }
            Section("Categories") {
                ForEach(categories, id: \.self) { category in
                    NavigationLink { LiveChannelListView(category: category, radioOnly: radioOnly) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: store.favoriteCategories.contains(category) ? "pin.fill" : "folder.fill")
                                .foregroundStyle(environment.theme.accentBright).frame(width: 44, height: 44)
                                .background(environment.theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category).font(.headline)
                                Text("\(channels[category, default: []].count) channels").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }.contextMenu { CategoryActions(category: category) }
                }
                if categories.isEmpty { Text("No visible categories. Add a playlist or edit category visibility.").foregroundStyle(.secondary) }
            }
            if !store.hiddenCategories.isEmpty {
                NavigationLink { HiddenIPTVSourcesView() } label: { Label("Hidden categories", systemImage: "eye.slash") }
            }
        }
            } else {
                LiveSearchResultsView(query: query, lineup: store.liveChannels.filter { $0.isRadio == radioOnly })
            }
        }
        .scrollContentBackground(.hidden).background(environment.theme.backgroundGradient)
        .navigationTitle(radioOnly ? "Radio" : "Live").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search channels and programs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit categories", systemImage: "slider.horizontal.3") { showEditor = true }
                    Button("Add playlist", systemImage: "plus") { showImport = true }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("live.options")
            }
        }
        .sheet(isPresented: $showImport) { NavigationStack { PlaylistImportView() } }
        .sheet(isPresented: $showEditor) { NavigationStack { CategoryEditorView(categories: allCategoryNames) } }
        .refreshable { await store.refreshIPTVAccounts(); await store.refreshGuide() }
        .task {
            if !store.iptvAccounts.isEmpty && !store.channels.contains(where: { $0.accountID != nil && $0.contentKind == nil }) { await store.refreshIPTVAccounts() }
            if store.programs.isEmpty { await store.refreshGuide() }
        }
    }
}

struct CategoryEditorView: View {
    let categories: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var store = VelagramStore.shared
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var filtered: [String] { categories.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search categories", text: $query).focused($searchFocused).submitLabel(.done)
                        .onSubmit { searchFocused = false }
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                }
            }
            Section {
                Button("Flip choices", systemImage: "arrow.triangle.2.circlepath") { apply(.invert) }
                Button("Hide all", systemImage: "eye.slash") { apply(.hide) }
                Button("Show all", systemImage: "eye") { apply(.show) }
            } footer: { Text("Actions apply to the categories matching your search. Turn a toggle on to hide that category.") }
            Section("\(filtered.count) categories") {
                ForEach(filtered, id: \.self) { category in
                    Toggle(isOn: Binding(get: { store.hiddenCategories.contains(category) }, set: { hidden in
                        if hidden { store.hideCategory(category) } else { store.restoreCategory(category) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(category)
                            Text(store.hiddenCategories.contains(category) ? "Hidden" : "Visible").font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityLabel("Hide " + category)
                }
            }
        }.navigationTitle("Edit categories")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private enum Action { case invert, hide, show }
    private func apply(_ action: Action) {
        let selected = Set(filtered)
        switch action {
        case .invert: store.hiddenCategories.formSymmetricDifference(selected)
        case .hide: store.hiddenCategories.formUnion(selected)
        case .show: store.hiddenCategories.subtract(selected)
        }
        store.persist()
    }
}

struct LiveChannelListView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var store = VelagramStore.shared
    @State private var query = ""
    @State private var group = "All"
    @State private var favoritesOnly = false
    @State private var showImport = false
    @State private var selection: LiveChannel?
    @State private var showChannelEditor = false
    var radioOnly = false
    var category: String = "All"
    init(category: String = "All", radioOnly: Bool = false, favoritesOnly: Bool = false) {
        self.category = category; self.radioOnly = radioOnly
        _group = State(initialValue: category); _favoritesOnly = State(initialValue: favoritesOnly)
    }

    private var allChannels: [LiveChannel] { store.liveChannels.filter { $0.isRadio == radioOnly } }
    private var filtered: [LiveChannel] {
        allChannels.filter { channel in
            (group == "All" || channel.group == group) && (!favoritesOnly || store.isFavorite(channel)) &&
            store.matchesLiveSearch(channel, query: query)
        }
    }
    var body: some View {
        Group {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LiveSearchResultsView(query: query, lineup: allChannels.filter { (group == "All" || $0.group == group) && (!favoritesOnly || store.isFavorite($0)) })
                    .scrollContentBackground(.hidden)
            } else {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(radioOnly ? "YOUR DAILY SOUNDTRACK" : "ON AIR, RIGHT NOW")
                        .font(.caption.weight(.bold)).tracking(2).foregroundStyle(environment.theme.accentBright)
                    Text(favoritesOnly ? "Favorites" : category == "All" ? "All channels" : category).font(.largeTitle.bold())
                    Text(radioOnly ? "Stations from home. Wherever you are." : "Your channels, together in one place.")
                        .foregroundStyle(.secondary)
                }.padding(.top, 16)
                IPTVLoadingStatus()
                if !store.recent.filter({ $0.isRadio == radioOnly && $0.contentKind == nil && !store.hiddenCategories.contains($0.group) && !store.hiddenChannelIDs.contains($0.id) && (category == "All" || $0.group == category) }).isEmpty && query.isEmpty && !favoritesOnly {
                    Text("Recently played").font(.title3.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach((store.combineChannelSources ? ChannelSources.grouped(store.recent) : store.recent).filter { $0.isRadio == radioOnly && $0.contentKind == nil && !store.hiddenCategories.contains($0.group) && !store.hiddenChannelIDs.contains($0.id) && (category == "All" || $0.group == category) }.prefix(8)) { channel in
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
                    NavigationLink { ProgramGuideView(lineup: filtered) } label: { Label("Guide", systemImage: "list.bullet.rectangle") }
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
                                    CatchupChannelBadge(channel: channel)
                                    Text(store.now(channel).map { "Now · " + $0.title } ?? channel.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if !query.isEmpty {
                                        ForEach(store.schedule(channel).filter { $0.title.localizedCaseInsensitiveContains(query) }.prefix(3)) { program in
                                            Text(program.title + " · " + program.start.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption).foregroundStyle(environment.theme.accentBright).lineLimit(2)
                                        }
                                    }
                                    if let next = store.schedule(channel).first(where: { $0.start > .now }) {
                                        Text("Next · " + next.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(environment.theme.accentBright)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { store.toggleFavorite(channel) } label: {
                            Image(systemName: store.isFavorite(channel) ? "star.fill" : "star").padding(8)
                        }.accessibilityLabel("Favorite \(channel.name)")
                    }
                    .padding(12).background(VelagramTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .contextMenu {
                        let sources = store.sources(for: channel)
                        if sources.count > 1 {
                            Menu("Default source") {
                                ForEach(sources) { source in
                                    Button { store.setDefaultSource(source, for: channel) } label: {
                                        Label(source.name, systemImage: store.defaultSource(for: channel).id == source.id ? "checkmark.circle.fill" : "circle")
                                    }
                                }
                            }
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
            }
        }
        .background(environment.theme.backgroundGradient)
        .navigationTitle(category == "All" ? "Channels" : category).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search channels and programs")
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Edit category", systemImage: "slider.horizontal.3") { showChannelEditor = true }
                Button("Add playlist", systemImage: "plus") { showImport = true }
            } label: { Image(systemName: "ellipsis.circle") }
        } }
        .sheet(isPresented: $showChannelEditor) {
            NavigationStack { ChannelEditorView(category: category, radioOnly: radioOnly) }
        }
        .sheet(isPresented: $showImport) { NavigationStack { PlaylistImportView() } }
        .fullScreenCover(item: $selection) { DirectPlayerView(channel: $0, lineup: filtered) }
        .refreshable { await store.refreshIPTVAccounts(); await store.refreshGuide() }
        .task {
            if !store.iptvAccounts.isEmpty && !store.channels.contains(where: { $0.accountID != nil && $0.contentKind == nil }) {
                await store.refreshIPTVAccounts()
            }
            await store.refreshGuide()
        }
    }
}

struct ChannelEditorView: View {
    let category: String
    let radioOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var store = VelagramStore.shared
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var choosingDestination = false
    @State private var destinationQuery = ""
    private var channels: [LiveChannel] {
        store.orderedChannels((BundledChannels.load() + store.channels).filter {
            $0.contentKind == nil && $0.isRadio == radioOnly && (category == "All" || $0.group == category)
        })
    }
    var body: some View {
        List {
            Section {
                Toggle("Combine channel sources", isOn: $store.combineChannelSources)
                    .onChange(of: store.combineChannelSources) { store.persist() }
                Button(selecting ? "Finish selecting" : "Select multiple channels", systemImage: "checkmark.circle") {
                    selecting.toggle(); selected = []
                }
                if selecting {
                    HStack {
                        Text("\(selected.count) selected").font(.caption)
                        Spacer()
                        Button("Select all") { selected = Set(channels.map(\.id)) }
                        Button("Clear") { selected = [] }
                    }
                    Button("Send to top", systemImage: "arrow.up.to.line") { move(to: 0) }.disabled(selected.isEmpty)
                    Button("Send to bottom", systemImage: "arrow.down.to.line") { move(to: channels.count) }.disabled(selected.isEmpty)
                    Button("Move before…", systemImage: "arrow.up.arrow.down") { choosingDestination = true }.disabled(selected.isEmpty || selected.count == channels.count)
                }
            }
            Section {
                ForEach(channels) { channel in
                    HStack {
                        if selecting {
                            Button {
                                if !selected.insert(channel.id).inserted { selected.remove(channel.id) }
                            } label: {
                                Image(systemName: selected.contains(channel.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).padding(.vertical, 8)
                            }.buttonStyle(.borderless).accessibilityLabel("Select " + channel.name)
                                .accessibilityValue(selected.contains(channel.id) ? "Selected" : "Not selected")
                        }
                        Toggle(channel.name, isOn: Binding(get: { !store.hiddenChannelIDs.contains(channel.id) }, set: { visible in
                            let ids = store.combineChannelSources
                                ? (BundledChannels.load() + store.channels).filter { ChannelSources.key($0) == ChannelSources.key(channel) }.map(\.id)
                                : [channel.id]
                            if visible { store.hiddenChannelIDs.subtract(ids) } else { store.hiddenChannelIDs.formUnion(ids) }
                            store.persist()
                        }))
                    }
                }.onMove { source, destination in
                    let ids = channels.map(\.id)
                    if selecting && source.contains(where: { selected.contains(ids[$0]) }) { move(to: destination) }
                    else {
                        var ordered = ids
                        ordered.move(fromOffsets: source, toOffset: destination)
                        store.applyChannelOrder(ordered)
                    }
                }
            } footer: { Text("Drag to reorder. Drag a selected channel to move the whole selection, or use the bulk move buttons. Selected channels keep their relative order. Visibility switches only hide or show channels.") }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Edit category")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $choosingDestination) {
            NavigationStack {
                List(channels.filter { !selected.contains($0.id) && (destinationQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(destinationQuery)) }) { channel in
                    Button(channel.name) {
                        if let offset = channels.firstIndex(where: { $0.id == channel.id }) { move(to: offset) }
                        choosingDestination = false
                    }
                }.navigationTitle("Move selection before")
                    .searchable(text: $destinationQuery, prompt: "Find destination channel")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingDestination = false } } }
            }
        }
    }
    private func move(to destination: Int) { store.moveChannelSelection(selected, in: channels.map(\.id), toOffset: destination) }
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
            IPTVLoadingStatus()
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
            if !store.iptvAccounts.isEmpty {
                Section("Connected accounts") {
                    ForEach(store.iptvAccounts) { account in Text(account.name) }
                    Button("Refresh channels, movies & series") { Task { await store.refreshIPTVAccounts() } }.disabled(store.busy)
                }
            }
            Section("Program guide") {
                TextField("XMLTV guide URL", text: $store.guideURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Save and refresh guide") { store.persist(); Task { await store.refreshGuide() } }
                if let status = store.guideStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
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

struct IPTVLoadingStatus: View {
    @State private var store = VelagramStore.shared
    var body: some View {
        if let status = store.importStatus {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text(status).font(.subheadline)
                    Text("\(store.channels.filter { $0.contentKind == nil }.count) live · \(store.channels.filter { $0.contentKind != nil }.count) on demand · \(store.iptvSeries.count) series")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12).accessibilityElement(children: .combine)
        } else if store.guideLoading {
            ProgressView("Updating program guide…")
        } else if let summary = store.importSummary {
            HStack(alignment: .top) {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.importSummary = nil } label: { Image(systemName: "xmark.circle") }
                    .accessibilityLabel("Dismiss import status")
            }.padding(12)
        }
    }
}

struct CategoryActions: View {
    let category: String
    var onHide: () -> Void = {}
    @State private var store = VelagramStore.shared
    var body: some View {
        Button(store.favoriteCategories.contains(category) ? "Unpin category" : "Favorite & pin category", systemImage: "pin") {
            store.toggleCategoryFavorite(category)
        }
        Button("Hide category", systemImage: "eye.slash") { store.hideCategory(category); onHide() }
    }
}

struct HiddenIPTVSourcesView: View {
    @State private var store = VelagramStore.shared
    var body: some View {
        List {
            Section {
                ForEach(store.hiddenCategories.sorted(), id: \.self) { category in
                    HStack { Text(category); Spacer(); Button("Restore") { store.restoreCategory(category) } }
                }
                if store.hiddenCategories.isEmpty { Text("No hidden IPTV categories.").foregroundStyle(.secondary) }
            } footer: { Text("Hidden categories are excluded from Live TV, on demand, the guide, source scans, and category catalog requests. Restore a category, then refresh to load its latest catalog and guide.") }
            if !store.hiddenCategories.isEmpty {
                Button("Restore all categories") { for category in store.hiddenCategories { store.restoreCategory(category) } }
            }
            Button("Refresh IPTV & guide") { Task { await store.refreshIPTVAccounts(); await store.refreshGuide() } }.disabled(store.busy)
            IPTVLoadingStatus()
        }.navigationTitle("Hidden IPTV sources")
    }
}

private struct GuideRow: Identifiable, Sendable {
    var id: String { channel.id }
    let channel: LiveChannel
    let programs: [GuideProgram]
}
private struct GuideChoice: Identifiable {
    var id: String { channel.id + program.id }
    let channel: LiveChannel
    let program: GuideProgram
}

struct ProgramGuideView: View {
    var lineup: [LiveChannel]? = nil
    @EnvironmentObject private var environment: AppEnvironment
    var onWatchChannel: ((LiveChannel) -> Void)? = nil
    var onWatchReplay: ((LiveChannel) -> Void)? = nil
    @State private var store = VelagramStore.shared
    @State private var query = ""
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var category = "All"
    @State private var rows: [GuideRow] = []
    @State private var preparing = false
    @State private var choice: GuideChoice?
    @State private var selected: LiveChannel?
    @State private var replay: PlayableStream?
    private var categories: [String] { ["All"] + store.sortedCategories(Set((lineup ?? store.liveChannels).map(\.group))) }
    private var requestID: String { "\(day.timeIntervalSince1970)|\(query)|\(category)|\(store.guideRevision)|\(store.channelRevision)|\(store.hiddenCategories.sorted())|\(store.hiddenChannelIDs.sorted())|\(store.channelOrder)|\(lineup?.map(\.id) ?? [])" }
    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { dates in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack {
                        ForEach(store.guideDays, id: \.self) { date in
                            let offset = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: date).day
                            Button { day = date } label: {
                                VStack(spacing: 4) {
                                    Text(offset == -1 ? "Yesterday" : offset == 0 ? "Today" : offset == 1 ? "Tomorrow" : date.formatted(.dateTime.weekday(.abbreviated)))
                                    Text(date.formatted(.dateTime.day().month(.abbreviated)))
                                }.font(.caption.weight(.semibold))
                                    .frame(minWidth: 64).padding(.horizontal, 10).padding(.vertical, 8)
                                    .foregroundStyle(day == date ? environment.theme.accentBright : Color.primary)
                                    .background(day == date ? environment.theme.accent.opacity(0.18) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(day == date ? environment.theme.accent.opacity(0.5) : Color.clear) }
                            }.buttonStyle(.plain).id(date)
                                .accessibilityIdentifier("epg.day." + String(Int(date.timeIntervalSince1970)))
                                .accessibilityValue(day == date ? "Selected" : "")
                        }
                    }.padding(.horizontal)
                }
                .frame(height: 64).accessibilityIdentifier("epg.days")
                .task(id: store.guideDays) { dates.scrollTo(day, anchor: .center) }
                .onChange(of: day) { _, value in withAnimation { dates.scrollTo(value, anchor: .center) } }
            }
            HStack {
                Picker("Category", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                    .contextMenu { if category != "All" { CategoryActions(category: category, onHide: { category = "All" }) } }
                Spacer()
                Label("Catch-up", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.orange)
                Text("\(rows.count) channels").font(.caption).foregroundStyle(.secondary)
                if preparing || store.guideLoading { ProgressView().controlSize(.small) }
            }.padding(.horizontal)
            if rows.isEmpty && !preparing {
                ContentUnavailableView("No programs for this day", systemImage: "calendar", description: Text(store.guideStatus ?? "Refresh the XMLTV guide or choose another day or category."))
            } else {
                GuideTimelineGrid(rows: rows, day: $day, onChannel: { watchChannel($0) }, onProgram: { choice = $0 })
            }
        }
        .background(environment.theme.backgroundGradient)
        .onAppear { AppOrientationController.shared.beginPlayback(using: .autoRotate) }
        .onDisappear { AppOrientationController.shared.endPlayback() }
        .navigationTitle("Program guide").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a channel")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if rows.isEmpty && !preparing {
                    Button("Now", systemImage: "clock") { day = Calendar.current.startOfDay(for: .now) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { Button { Task { await store.refreshGuide() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.guideLoading).accessibilityLabel("Refresh guide") }
        }
        .task { if store.programs.isEmpty { await store.refreshGuide() } }
        .task(id: requestID) { await prepareRows() }
        .sheet(item: $choice) { choice in
            NavigationStack {
                GuideProgramDetails(channel: choice.channel, program: choice.program, watchLive: { self.choice = nil; watchChannel(choice.channel) }, watchReplay: { channel in
                    self.choice = nil
                    if let onWatchReplay { onWatchReplay(channel) } else { replay = OnDemandLibraryView.playable(channel) }
                })
            }.presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $selected) { DirectPlayerView(channel: $0, lineup: rows.map(\.channel)) }
        .fullScreenCover(item: $replay) { IPTVSourcePlayerView(stream: $0) }
    }
    private func watchChannel(_ channel: LiveChannel) {
        if let onWatchChannel { onWatchChannel(channel) } else { selected = channel }
    }
    private func prepareRows() async {
        preparing = true
        defer { preparing = false }
        let channels = (lineup ?? store.liveChannels).filter { !store.hiddenChannelIDs.contains($0.id) && !store.hiddenCategories.contains($0.group) && (category == "All" || $0.group == category) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
        let input = channels.map { GuideRow(channel: $0, programs: store.schedule($0)) }
        let start = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let result = await Task.detached(priority: .userInitiated) {
            input.compactMap { row -> GuideRow? in
                let programs = row.programs.filter { $0.end > start && $0.start < end }
                return GuideRow(channel: row.channel, programs: programs)
            }
        }.value
        guard !Task.isCancelled else { return }
        rows = result
    }
}

private struct GuideTimelineGrid: View {
    let rows: [GuideRow]
    @Binding var day: Date
    let onChannel: (LiveChannel) -> Void
    let onProgram: (GuideChoice) -> Void
    private let channelWidth: CGFloat = 142
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    private var hourWidth: CGFloat { 180 * min(8, max(0.75, zoom * pinch)) }
    private var hours: Int { Int(Calendar.current.date(byAdding: .day, value: 1, to: day)!.timeIntervalSince(day) / 3600) }
    private var width: CGFloat { channelWidth + CGFloat(hours) * hourWidth }
    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        timeHeader
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 1) {
                                ForEach(rows) { row in
                                    GuideTimelineRow(row: row, day: day, hours: hours, hourWidth: hourWidth, channelWidth: channelWidth, onChannel: onChannel, onProgram: onProgram)
                                }
                            }
                        }.frame(height: max(0, viewport.size.height - 42))
                    }.frame(width: width)

                }
                .accessibilityIdentifier("epg.timeline")
                .accessibilityValue("Zoom \(Int(zoom * 100)) percent")
                .simultaneousGesture(MagnifyGesture().updating($pinch) { value, state, _ in
                    state = value.magnification
                }.onEnded { value in zoom = min(8, max(0.75, zoom * value.magnification)) })
                .task(id: day) { proxy.scrollTo(Calendar.current.isDateInToday(day) ? max(0, Calendar.current.component(.hour, from: .now) - 1) : 0, anchor: .leading) }
                .overlay(alignment: .bottomTrailing) {
                    Button("Now", systemImage: "clock") {
                        day = Calendar.current.startOfDay(for: .now)
                        withAnimation { proxy.scrollTo(max(0, Calendar.current.component(.hour, from: .now) - 1), anchor: .leading) }
                    }.buttonStyle(.borderedProminent).tint(.blue).padding()
                }
            }
        }
    }
    private var timeHeader: some View {
        HStack(spacing: 0) {
            Text("Channel").font(.caption.bold()).frame(width: channelWidth, height: 42)
                .background(VelagramTheme.surface)
                .visualEffect { content, geometry in content.offset(x: max(0, -geometry.frame(in: .scrollView(axis: .horizontal)).minX)) }.zIndex(2)
            HStack(spacing: 0) {
                ForEach(0..<hours, id: \.self) { hour in
                    Text(day.addingTimeInterval(Double(hour) * 3600).formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit()).frame(width: hourWidth, height: 42, alignment: .leading).id(hour)
                }
            }
        }.background(VelagramTheme.elevatedSurface)
    }
}

private struct GuideTimelineRow: View {
    let row: GuideRow
    let day: Date
    let hours: Int
    let hourWidth: CGFloat
    let channelWidth: CGFloat
    let onChannel: (LiveChannel) -> Void
    let onProgram: (GuideChoice) -> Void
    private var end: Date { day.addingTimeInterval(Double(hours) * 3600) }
    var body: some View {
        HStack(spacing: 0) {
            Button { onChannel(row.channel) } label: {
                HStack(spacing: 8) {
                    ChannelArtwork(channel: row.channel).frame(width: 36, height: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.channel.name).font(.caption.bold()).lineLimit(2)
                        if row.channel.supportsCatchup {
                            Label("Catch-up", systemImage: "clock.arrow.circlepath")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8).frame(width: channelWidth, height: 88)
                    .background(VelagramTheme.surface)
                    .overlay { if row.channel.supportsCatchup { Color.orange.opacity(0.08).allowsHitTesting(false) } }
            }.buttonStyle(.plain)
                .accessibilityLabel(row.channel.name + (row.channel.supportsCatchup ? ", catch-up available" : ""))
                .visualEffect { content, geometry in content.offset(x: max(0, -geometry.frame(in: .scrollView(axis: .horizontal)).minX)) }.zIndex(2)
            ZStack(alignment: .topLeading) {
                Color.white.opacity(0.03)
                if row.programs.isEmpty {
                    Text("No guide available").font(.caption).foregroundStyle(.secondary).padding(12)
                }
                ForEach(row.programs) { program in
                    let canReplay = row.channel.supportsCatchup && program.end <= .now && program.start >= Date.now.addingTimeInterval(-Double(row.channel.archiveDays ?? 0) * 86400)
                    let start = max(day, program.start)
                    let stop = min(end, program.end)
                    let cellWidth = CGFloat(stop.timeIntervalSince(start) / 3600) * hourWidth
                    Button { onProgram(GuideChoice(channel: row.channel, program: program)) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                if canReplay { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange) }
                                Text(program.title).font(.caption.weight(.semibold)).lineLimit(2)
                            }
                            Text(program.start.formatted(date: .omitted, time: .shortened) + " – " + program.end.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(8).frame(width: max(1, cellWidth - 2), height: 86, alignment: .leading)
                            .background(program.start <= .now && program.end > .now ? Color.blue.opacity(0.32) : canReplay ? Color.orange.opacity(0.16) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).clipped()
                        .accessibilityLabel(program.title + (canReplay ? ", catch-up available" : ""))
                        .offset(x: CGFloat(start.timeIntervalSince(day) / 3600) * hourWidth)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if context.date >= day && context.date < end {
                        Rectangle().fill(.blue).frame(width: 2, height: 88)
                            .offset(x: CGFloat(context.date.timeIntervalSince(day) / 3600) * hourWidth)
                            .allowsHitTesting(false)
                    }
                }
            }.frame(width: CGFloat(hours) * hourWidth, height: 88).clipped().zIndex(0)
        }.frame(height: 88)
    }
}

private struct GuideProgramDetails: View {
    let channel: LiveChannel
    let program: GuideProgram
    let watchLive: () -> Void
    let watchReplay: (LiveChannel) -> Void
    @State private var store = VelagramStore.shared
    var body: some View {
        List {
            Section(channel.name) {
                Text(program.title).font(.title2.bold())
                Text(program.start.formatted(date: .abbreviated, time: .shortened) + " – " + program.end.formatted(date: .omitted, time: .shortened))
                if !program.summary.isEmpty { Text(program.summary) }
            }
            Section {
                if program.start <= .now && program.end > .now { Button("Watch live", systemImage: "play.fill", action: watchLive) }
                if let replay = store.catchup(channel, program: program) { Button("Watch catch-up", systemImage: "clock.arrow.circlepath") { watchReplay(replay) } }
                else if program.end <= .now { Text("Catch-up is unavailable for this program.").foregroundStyle(.secondary) }
            }
        }.navigationTitle("Program details").navigationBarTitleDisplayMode(.inline)
    }
}

struct ChannelGuideView: View {
    let channel: LiveChannel
    var lineup: [LiveChannel]? = nil
    var watchLive: ((LiveChannel) -> Void)? = nil
    var watchReplay: (LiveChannel) -> Void
    @State private var store = VelagramStore.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let programs = store.schedule(channel)
            let current = programs.first { $0.start <= context.date && $0.end > context.date } ?? programs.first { $0.start > context.date }
            ScrollViewReader { proxy in
                List {
                    if programs.isEmpty { Text("No guide available for this channel.").foregroundStyle(.secondary) }
                    ForEach(programs) { program in
                        let isNow = program.start <= context.date && program.end > context.date
                        VStack(alignment: .leading, spacing: 5) {
                            Text(isNow ? "On now" : program.end <= context.date ? "Previously" : "Up next")
                                .font(.caption.weight(isNow ? .bold : .regular)).foregroundStyle(isNow ? Color.blue : Color.secondary)
                            Text(program.title).font(.headline).foregroundStyle(isNow ? Color.blue : Color.primary)
                            Text(program.start.formatted(date: .abbreviated, time: .shortened) + " – " + program.end.formatted(date: .omitted, time: .shortened)).font(.caption)
                            if let replay = store.catchup(channel, program: program) { Button("Watch catch-up") { watchReplay(replay) } }
                        }.id(program.id).listRowBackground(isNow ? Color.blue.opacity(0.14) : Color.clear)
                            .accessibilityIdentifier(isNow ? "epg.onNow" : "epg.program")
                    }
                }
                .task(id: "\(channel.id)|\(store.guideRevision)") {
                    await Task.yield()
                    if let current { proxy.scrollTo(current.id, anchor: .top) }
                }
            }
        }.navigationTitle(channel.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { ProgramGuideView(lineup: lineup, onWatchChannel: watchLive, onWatchReplay: watchReplay) } label: { Text("Full EPG") } } }
    }
}

private struct LiveProgramMatch: Identifiable, Sendable {
    var id: String { channel.id + ":" + program.id }
    let channel: LiveChannel
    let program: GuideProgram
}
private struct LiveSearchSnapshot: Sendable {
    var channels: [LiveChannel] = []
    var programs: [LiveProgramMatch] = []
}

private struct CatchupChannelBadge: View {
    let channel: LiveChannel
    var body: some View {
        if channel.supportsCatchup {
            Label("Catch-up · \(channel.archiveDays ?? 0) days", systemImage: "clock.arrow.circlepath")
                .font(.caption2.weight(.semibold)).foregroundStyle(.blue)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private struct LiveSearchResultsView: View {
    let query: String
    let lineup: [LiveChannel]
    @State private var store = VelagramStore.shared
    @State private var result = LiveSearchSnapshot()
    @State private var sortOrder = "Recommended"
    @State private var nameFilter = ""
    @State private var descriptionFilter = ""
    private var filteredChannels: [LiveChannel] {
        let matches = result.channels.filter { channel in
            contains(channel.name, nameFilter) && (descriptionFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.schedule(channel).contains { contains($0.summary, descriptionFilter) })
        }
        guard sortOrder.hasPrefix("Title") else { return matches }
        return matches.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order == .orderedSame { return $0.id < $1.id }
            return sortOrder == "Title A–Z" ? order == .orderedAscending : order == .orderedDescending
        }
    }
    private var filteredPrograms: [LiveProgramMatch] {
        let matches = result.programs.filter { contains($0.program.title, nameFilter) && contains($0.program.summary, descriptionFilter) }
        guard sortOrder != "Recommended" else { return matches }
        return matches.sorted {
            if sortOrder.hasPrefix("Title") {
                let order = $0.program.title.localizedStandardCompare($1.program.title)
                if order != .orderedSame { return sortOrder == "Title A–Z" ? order == .orderedAscending : order == .orderedDescending }
            } else if $0.program.start != $1.program.start {
                return sortOrder == "Date · newest first" ? $0.program.start > $1.program.start : $0.program.start < $1.program.start
            }
            return $0.id < $1.id
        }
    }
    private func contains(_ text: String, _ filter: String) -> Bool {
        let value = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || text.localizedStandardContains(value)
    }
    @State private var searching = false
    @State private var limit = 60
    @State private var selectedChannel: LiveChannel?
    @State private var selectedProgram: GuideChoice?
    @State private var replay: PlayableStream?
    private var requestID: String { "\(query)|\(store.guideRevision)|\(store.channelRevision)|\(lineup.map(\.id))" }
    var body: some View {
        let filteredChannels = self.filteredChannels
        let filteredPrograms = self.filteredPrograms
        List {
            Section {
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(["Recommended", "Date · newest first", "Date · oldest first", "Title A–Z", "Title Z–A"], id: \.self) { Text($0).tag($0) }
                }
                TextField("Contains in name", text: $nameFilter)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Contains in description", text: $descriptionFilter)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !nameFilter.isEmpty || !descriptionFilter.isEmpty {
                    Button("Clear filters") { nameFilter = ""; descriptionFilter = "" }
                }
            } footer: {
                Text("Dates use program airtimes. Channels keep their existing order when sorting by date. Name filters match channel names or program titles; channel descriptions match guide summaries.")
            }
            Text("Results for “\(query)”").font(.caption).foregroundStyle(.secondary)
            if searching { ProgressView("Searching channels and programs…") }
            if !filteredChannels.isEmpty {
                Section("Channels · \(filteredChannels.count)") {
                    ForEach(filteredChannels) { channel in
                        Button { selectedChannel = channel } label: {
                            HStack(spacing: 12) {
                                ChannelArtwork(channel: channel).frame(width: 48, height: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(channel.name).font(.headline)
                                    Text(store.now(channel)?.title ?? channel.group).font(.caption).foregroundStyle(.secondary)
                                    CatchupChannelBadge(channel: channel)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill").foregroundStyle(.blue)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("live.search.channel." + channel.id)
                    }
                }
            }
            if !filteredPrograms.isEmpty {
                Section("Programs · \(filteredPrograms.count)") {
                    ForEach(filteredPrograms.prefix(limit)) { match in
                        Button { selectedProgram = GuideChoice(channel: match.channel, program: match.program) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(match.program.title).font(.headline)
                                Text(match.channel.name).font(.subheadline).foregroundStyle(.secondary)
                                Text(match.program.start.formatted(date: .abbreviated, time: .shortened) + " – " + match.program.end.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                Label(match.program.end <= .now ? "Catch-up" : match.program.start <= .now ? "On now" : "Upcoming", systemImage: match.program.end <= .now ? "clock.arrow.circlepath" : "calendar")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                            }.padding(.vertical, 4)
                        }.buttonStyle(.plain).accessibilityIdentifier("live.search.program." + match.id)
                    }
                    if filteredPrograms.count > limit { Button("Show more programs") { limit += 60 } }
                }
            }
            let categories = store.sortedCategories(Set(lineup.map(\.group))).filter { $0.localizedStandardContains(query) && contains($0, nameFilter) && descriptionFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories, id: \.self) { category in
                        NavigationLink { LiveChannelListView(category: category, radioOnly: lineup.first?.isRadio ?? false) } label: { Label(category, systemImage: "folder") }
                    }
                }
            }
            if !searching && filteredChannels.isEmpty && filteredPrograms.isEmpty && categories.isEmpty {
                Text("No matching channels or playable programs.").foregroundStyle(.secondary)
            }
        }

        .onChange(of: sortOrder) { limit = 60 }
        .onChange(of: nameFilter) { limit = 60 }
        .onChange(of: descriptionFilter) { limit = 60 }
        .task(id: requestID) { await search() }
        .sheet(item: $selectedProgram) { choice in
            NavigationStack {
                GuideProgramDetails(channel: choice.channel, program: choice.program, watchLive: { selectedProgram = nil; selectedChannel = choice.channel }, watchReplay: { channel in
                    selectedProgram = nil; replay = OnDemandLibraryView.playable(channel)
                })
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedProgram = nil } } }
            }.presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $selectedChannel) { DirectPlayerView(channel: $0, lineup: lineup) }
        .fullScreenCover(item: $replay) { IPTVSourcePlayerView(stream: $0) }

    }
    private func search() async {
        searching = true
        result = LiveSearchSnapshot(); limit = 60
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        let channels = lineup
        let programs = store.programs
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let now = Date.now
        let matches = await Task.detached(priority: .userInitiated) {
            let byGuide = Dictionary(grouping: channels.filter { $0.guideID?.isEmpty == false }, by: { $0.guideID! })
            var snapshot = LiveSearchSnapshot(channels: channels.filter { channel in terms.allSatisfy { channel.name.localizedStandardContains($0) } })
            for program in programs where terms.allSatisfy({ program.title.localizedStandardContains($0) || program.summary.localizedStandardContains($0) }) {
                for channel in byGuide[program.channelID, default: []] {
                    if program.end > now || (channel.supportsCatchup && program.start >= now.addingTimeInterval(-Double(channel.archiveDays ?? 0) * 86400)) {
                        snapshot.programs.append(LiveProgramMatch(channel: channel, program: program))
                    }
                }
            }
            snapshot.programs.sort {
                let left = $0.program.end <= now ? 1 : 0
                let right = $1.program.end <= now ? 1 : 0
                if left != right { return left < right }
                return left == 1 ? $0.program.start > $1.program.start : $0.program.start < $1.program.start
            }
            return snapshot
        }.value
        guard !Task.isCancelled else { return }
        result = matches; searching = false
    }
}

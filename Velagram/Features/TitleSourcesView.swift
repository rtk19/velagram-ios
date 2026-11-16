import SwiftUI
import Observation

@MainActor @Observable final class TitleSourcesModel {
    var web: [PlaybackCandidate] = []
    var telegram: [TelegramMedia] = []
    var searching = true
    var scanProgress: TelegramScanProgress?
    var statuses: [String: String] = [:]
    var failure: String?
    var selectedWeb: PlayableStream?
    var selectedTelegram: TelegramMedia?
    var openingID: String?
    private var generation = UUID()

    func scan(context: PlaybackLookupContext, providers: [any PlaybackProvider], store: TelegramStore, pages: Int, enrichedContext: Task<PlaybackLookupContext, Never>? = nil) async {
        let token = UUID(); generation = token
        scanProgress = nil
        web = []; telegram = []; statuses = [:]; failure = nil; searching = true
        defer { if generation == token { searching = false } }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers + [VelagramStore.shared.iptvProvider()] + VelagramStore.shared.mediaServerProviders() {
                statuses[provider.id] = "Searching…"
                group.addTask { [weak self] in
                    do {
                        func lookup(_ context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
                            try await withThrowingTaskGroup(of: [PlaybackCandidate].self) { timed in
                                timed.addTask { try await provider.candidates(for: context) }
                                timed.addTask { try await Task.sleep(for: .seconds(30)); throw AppError.noStream }
                                defer { timed.cancelAll() }
                                return try await timed.next() ?? []
                            }
                        }
                        // Personal libraries can match IDs and original titles immediately.
                        // Don't hold them behind catalog translation or Telegram startup.
                        if (provider.id == "iptv" || provider.id.hasPrefix("server:")), enrichedContext != nil {
                            let immediate = try await lookup(context)
                            await self?.receive(immediate, provider: provider.id, token: token)
                            if provider.id.hasPrefix("server:"), !immediate.isEmpty { return }
                        }
                        let context = await enrichedContext?.value ?? context
                        try Task.checkCancellation()
                        let results = try await lookup(context)
                        await self?.receive(results, provider: provider.id, token: token)
                    } catch { await self?.status(provider.id, "Unavailable", token: token) }
                }
            }
            statuses["telegram"] = "Connecting to Telegram…"
            do {
                group.addTask { [weak self, transport = store.transport] in
                    do {
                        await store.start()
                        for _ in 0..<40 {
                            let authorization = await store.authorization
                            let restoring = authorization == .null || authorization.type == "authorizationStateWaitTdlibParameters"
                            if !restoring { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        try Task.checkCancellation()
                        guard await store.ready else {
                            await self?.status("telegram", "Sign in to include Telegram", token: token)
                            return
                        }
                        let lookup = await enrichedContext?.value ?? context
                        try Task.checkCancellation()
                        await self?.status("telegram", "Searching your Telegram media…", token: token)
                        try await withThrowingTaskGroup(of: Void.self) { timed in
                            timed.addTask { [weak self] in
                                try await TelegramCatalogSearch(transport: transport).search(context: lookup, pages: pages, onProgress: { [weak self] progress in
                                    await self?.receiveProgress(progress, token: token)
                                }) { [weak self] media in
                                    await self?.receiveTelegram(media, store: store, token: token)
                                }
                            }
                            timed.addTask { try await Task.sleep(for: .seconds(120)); throw TelegramError(code: 408, message: "Search timed out. Available matches are shown; use Search deeper to continue.") }
                            defer { timed.cancelAll() }
                            _ = try await timed.next()
                        }
                        await self?.finishTelegram(token: token)
                    } catch { await self?.status("telegram", Task.isCancelled ? "Cancelled" : error.localizedDescription, token: token) }
                }
            }
            await group.waitForAll()
        }
    }
    private func receiveProgress(_ progress: TelegramScanProgress, token: UUID) {
        guard generation == token, !Task.isCancelled else { return }
        scanProgress = progress
    }
    private func receive(_ values: [PlaybackCandidate], provider: String, token: UUID) {
        guard generation == token, !Task.isCancelled else { return }
        var seen = Set(web.map(\.id)); web += values.filter { seen.insert($0.id).inserted }
        web.sort { $0.providerName.localizedStandardCompare($1.providerName) == .orderedAscending }
        let count = web.filter { $0.preference.providerID == provider }.count
        statuses[provider] = count == 0 ? "No matches" : "\(count) sources"
    }
    private func receiveTelegram(_ values: [TelegramMedia], store: TelegramStore, token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }; telegram = values
        for id in Set(values.map(\.chatID)) where store.chats[id] == nil {
            guard generation == token, !Task.isCancelled else { return }
            if let json = try? await store.transport.call("getChat", ["chat_id": .integer(id)], timeout: 5), let chat = TelegramChat(json) {
                store.chats[id] = chat
            }
        }
    }
    private func finishTelegram(token: UUID) { status("telegram", telegram.isEmpty ? "No matching files" : "\(TelegramReleaseGroup.group(telegram).count) releases · \(telegram.count) message locations", token: token) }
    private func status(_ provider: String, _ text: String, token: UUID) { if generation == token { statuses[provider] = text } }
    func open(_ candidate: PlaybackCandidate) async {
        guard openingID == nil else { return }; openingID = candidate.id; failure = nil
        defer { openingID = nil }
        do {
            if candidate.preference.providerID == "iptv" {
                selectedWeb = PlayableStream(candidate: candidate, source: try await candidate.resolve(), qualities: [])
            } else { selectedWeb = try await PlaybackDiscovery.prepare(candidate) }
        }
        catch { if !Task.isCancelled { failure = "This source could not be opened. Choose another release or retry." } }
    }
}

/// The primary playback entry point: pick the title first, then choose a release.
struct TitleSourcesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let request: PlaybackRequest
    let nextRequest: PlaybackRequest?
    @State private var model = TitleSourcesModel()
    @State private var pages = 4
    @State private var scanID = UUID()
    @State private var signIn = false
    @State private var downloads = TelegramDownloads.shared
    @State private var connectivity = OfflineConnectivity.shared
    @State private var showDownloads = false
    @State private var deletionError: String?
    @State private var removal: TelegramMedia?
    @State private var filter = "All"
    @State private var searchText = ""
    @State private var sort: SourceResultSort = .quality
    @State private var ascending = false
    @AppStorage("telegram.scan.showProgress") private var showScanProgress = true
    private let store = TelegramStore.shared
    private var showWeb: Bool { filter != "Telegram" }
    private var showTelegram: Bool { filter == "All" || filter == "Telegram" }

    private func info(_ item: TelegramMedia) -> SourceResultInfo {
        SourceResultInfo(id: item.id, title: item.name, origin: store.chats[item.chatID]?.title ?? "Telegram", metadata: TelegramCatalogMatching.metadata(item), date: item.date, additionalText: item.caption)
    }
    private func info(_ item: PlaybackCandidate) -> SourceResultInfo {
        SourceResultInfo(id: item.id, title: item.preference.serverName, origin: item.providerName, metadata: item.displayMetadata, date: nil)
    }
    private var telegramResults: [TelegramReleaseGroup] {
        let local = downloads.available(for: request)
        return TelegramReleaseGroup.group(downloads.knownTelegram(for: request, store: store) + model.telegram).compactMap { group in
            guard !group.locations.contains(where: { media in local.contains { OfflineLibraryIndex.sameRelease($0.media, media) } }) else { return nil }
            let locations = group.locations.filter { info($0).matches(searchText) }
            return locations.isEmpty ? nil : TelegramReleaseGroup(id: group.id, locations: locations)
        }.sorted { SourceResultInfo.ordered(info($0.representative), info($1.representative), by: sort, ascending: ascending) }
    }
    private var webResults: [PlaybackCandidate] {
        let localIDs = Set(downloads.available(for: request).compactMap(\.sourceID))
        return model.web.filter { candidate in
            guard info(candidate).matches(searchText), !localIDs.contains(candidate.id) else { return false }
            switch filter {
            case "All": return true
            case "Servers": return candidate.preference.providerID.hasPrefix("server:")
            case "IPTV": return candidate.preference.providerID == "iptv"
            case "Web": return candidate.preference.providerID != "iptv" && !candidate.preference.providerID.hasPrefix("server:")
            default: return false
            }
        }.sorted { SourceResultInfo.ordered(info($0), info($1), by: sort, ascending: ascending) }
    }
    private enum Choice: Identifiable {
        case telegram(TelegramReleaseGroup), web(PlaybackCandidate)
        var id: String { switch self { case .telegram(let group): "telegram:" + group.id; case .web(let candidate): "web:" + candidate.id } }
    }
    private func info(_ choice: Choice) -> SourceResultInfo {
        switch choice { case .telegram(let group): info(group.representative); case .web(let candidate): info(candidate) }
    }
    private var choices: [Choice] {
        ((showTelegram ? telegramResults.map(Choice.telegram) : []) + (showWeb ? webResults.map(Choice.web) : []))
            .sorted {
                let last = library.sourceHistory(for: request).first
                if ($0.id == last) != ($1.id == last) { return $0.id == last }
                return SourceResultInfo.ordered(info($0), info($1), by: sort, ascending: ascending)
            }
    }

    @ViewBuilder private func playedBadge(_ identity: String) -> some View {
        let history = library.sourceHistory(for: request)
        if history.contains(identity) {
            let last = history.first == identity
            Label(last ? "Last played · Pinned" : "Recently played", systemImage: last ? "pin.fill" : "clock.arrow.circlepath")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(last ? environment.theme.accentBright : .secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(last ? environment.theme.accent.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
                .accessibilityIdentifier(last ? "source.lastPlayed" : "source.recentlyPlayed")
        }
    }

    @ViewBuilder private func cacheStatus(_ group: TelegramReleaseGroup, active: Bool) -> some View {
        let files = group.locations.compactMap { $0.fileID.flatMap { downloads.partialFiles[$0] ?? store.files[$0] } }
        if let file = files.filter({ !$0.localPath.isEmpty && FileManager.default.fileExists(atPath: $0.localPath) }).max(by: { $0.downloadedSize < $1.downloadedSize }), file.downloadedSize > 0, !file.completed, !active {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Partially cached", systemImage: "internaldrive")
                    Spacer()
                    if file.size > 0 {
                        Text(DownloadTransferProgress(received: file.downloadedSize, total: file.size, bytesPerSecond: 0, sampledAt: 0).percentage)
                    }
                }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if !active {
                    if file.size > 0 {
                        ProgressView(value: Double(min(file.downloadedSize, file.size)), total: Double(file.size))
                            .tint(environment.theme.accent.opacity(0.7))
                    }
                    Text(ByteCountFormatter.string(fromByteCount: file.downloadedSize, countStyle: .file) + " on device · Internet needed for the rest")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.accessibilityElement(children: .combine)
        }
    }

    private func localIdentity(_ item: TelegramSavedDownload) -> String {
        item.sourceID.map { "web:" + $0 } ?? "telegram:" + (TelegramReleaseGroup.group([item.media]).first?.id ?? item.media.id)
    }

    private var pinnedLocal: TelegramSavedDownload? {
        guard let last = library.sourceHistory(for: request).first else { return nil }
        return downloads.available(for: request).first { localIdentity($0) == last }
    }
    private var pinnedChoice: Choice? {
        guard pinnedLocal == nil, let last = library.sourceHistory(for: request).first else { return nil }
        return choices.first { $0.id == last }
    }
    private var otherChoices: [Choice] { choices.filter { $0.id != pinnedChoice?.id } }
    private var otherLocalSources: [TelegramSavedDownload] {
        downloads.available(for: request).filter { $0.id != pinnedLocal?.id }.sorted { $0.savedAt > $1.savedAt }
    }
    @ViewBuilder private func choiceRow(_ choice: Choice) -> some View {
        switch choice {
        case .telegram(let group): telegramRow(group)
        case .web(let candidate): webRow(candidate)
        }
    }

    private func deleteButton(_ media: TelegramMedia) -> some View {
        Button(role: .destructive) {
            removal = media
        } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
        .accessibilityLabel("Delete downloaded source")
    }
    private func localRow(_ item: TelegramSavedDownload) -> some View {
        let transfer = downloads.sources().first { OfflineLibraryIndex.sameRelease($0.media, item.media) }?.transferID
        return VStack(alignment: .leading, spacing: 10) {
            playedBadge(localIdentity(item))
            HStack {
                Button { model.selectedTelegram = item.media } label: {
                    Label(item.isCached ? "Cached · \(item.media.name)" : "Downloaded · \(item.media.name)", systemImage: item.isCached ? "internaldrive" : "checkmark.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                deleteButton(item.media)
                if item.isCached, transfer == nil {
                    Button { downloads.begin(item.media, store: store) } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("Keep download")
                }
            }
            if let transfer {
                if let progress = downloads.transferProgress[transfer] { DownloadTransferProgressView(progress: progress) }
                ConfirmCancelDownloadButton { downloads.cancelTransfer(transfer, store: store) }
            }
        }
    }
    private func telegramRow(_ group: TelegramReleaseGroup) -> some View {
        let item = group.representative
        let fileID = group.locations.compactMap(\.fileID).first { downloads.active[$0] != nil } ?? item.fileID
        let active = fileID.map { downloads.active[$0] != nil } ?? false
        let saved = downloads.saved.contains { !$0.isCached && OfflineLibraryIndex.sameRelease($0.media, item) }
        return VStack(alignment: .leading, spacing: 12) {
            playedBadge("telegram:" + group.id)
            HStack(alignment: .top, spacing: 12) {
                Button { model.selectedTelegram = item } label: {
                    SourceReleaseRow(title: item.name, provider: "Telegram", metadata: TelegramCatalogMatching.metadata(item), chatName: store.chats[item.chatID]?.title ?? (model.searching ? "Loading chat…" : "Chat unavailable"), messageDate: item.date)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityHint("Play this release")
                .accessibilityIdentifier("source.telegram.\(item.id)")
                if group.locations.contains(where: { media in media.fileID.flatMap { store.files[$0] }?.downloadedSize ?? 0 > 0 }) { deleteButton(item) }
                if let id = fileID {
                    SourceDownloadButton(active: active, saved: saved, progress: downloads.transferProgress["telegram:\(id)"]) {
                        if active { downloads.cancel(id, store: store) }
                        else if !saved { downloads.track(item, request: request, store: store); downloads.begin(item, store: store) }
                    }
                }
            }
            cacheStatus(group, active: active)
            if active, let id = fileID, let progress = downloads.transferProgress["telegram:\(id)"] {
                DownloadTransferProgressView(progress: progress)
            }
            if let id = fileID, let error = downloads.errors[id] { Text(error).font(.caption).foregroundStyle(.orange) }
            if group.locations.count > 1 {
                Text("\(group.locations.count) available copies").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
    private func webRow(_ candidate: PlaybackCandidate) -> some View {
        let active = downloads.webActive.contains(candidate.id)
        let saved = downloads.available(for: request).contains { $0.sourceID == candidate.id }
        let progress = downloads.transferProgress["web:" + candidate.id]
        return VStack(alignment: .leading, spacing: 12) {
            playedBadge("web:" + candidate.id)
            HStack(alignment: .top, spacing: 12) {
                Button { Task { await model.open(candidate) } } label: {
                    HStack {
                        SourceReleaseRow(title: candidate.preference.serverName, provider: candidate.providerName, metadata: candidate.displayMetadata, sourceIdentity: candidate.sourceIdentity)
                        if model.openingID == candidate.id { ProgressView() }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.openingID != nil)
                SourceDownloadButton(active: active, saved: saved, progress: progress) {
                    if active { downloads.cancelWeb(candidate.id) }
                    else if !saved { downloads.begin(candidate, request: request) }
                }
            }
            if active, let progress { DownloadTransferProgressView(progress: progress) }
            if let error = downloads.webErrors[candidate.id] { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(16)
    }
    var body: some View {
        Group {
            List {
                Section {
                    Text(request.displayTitle).font(.title2.bold())
                    Text("Choose a source to play").foregroundStyle(.secondary)
                    Picker("Sources", selection: $filter) {
                        ForEach(["All", "Telegram", "Web", "IPTV", "Servers"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    IPTVLoadingStatus()
                    if model.searching { HStack(spacing: 10) { ProgressView(); Text("Scanning sources…").foregroundStyle(.secondary); Spacer() } }
                    DisclosureGroup("Search details", isExpanded: $showScanProgress) {
                        if let progress = model.scanProgress {
                            ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                            Text("\(progress.completed)/\(progress.total) search options").font(.caption.monospacedDigit())
                            Text(progress.task).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        } else if model.searching {
                            Text("Loading title translations and preparing providers…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let failure = model.failure { Text(failure).foregroundStyle(.orange) }
                }
                if let pinnedLocal {
                    Section("Last played") { localRow(pinnedLocal) }
                } else if let pinnedChoice {
                    Section("Last played") {
                        choiceRow(pinnedChoice)
                            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                            .listRowBackground(Color.clear)
                            .background(VelagramTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(environment.theme.accent.opacity(0.35)) }
                    }
                }
                if !otherLocalSources.isEmpty {
                    Section("On this device · instant playback") {
                        ForEach(otherLocalSources) { item in localRow(item) }
                    }
                }
                Section("\(pinnedChoice == nil ? (filter == "All" ? "Sources" : filter) : "More sources") · \(otherChoices.count)") {
                    if showTelegram, !store.ready {
                        Button("Connect Telegram") { signIn = true }
                        Text("Sign in once to find matching files across your Telegram chats automatically.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(otherChoices) { choice in
                        choiceRow(choice)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .background(VelagramTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(VelagramTheme.border) }
                    if choices.isEmpty, !model.searching { Text(searchText.isEmpty ? (downloads.available(for: request).isEmpty ? "No matching sources found." : "No additional streaming sources found.") : "No results match this filter.").foregroundStyle(.secondary) }
                    if showTelegram { Text(model.statuses["telegram"] ?? "Preparing Telegram…").font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Button("Search deeper in Telegram") { pages += 2; scanID = UUID() }.disabled(model.searching || !store.ready)
                    DisclosureGroup("Provider status") {
                        ForEach(model.statuses.keys.sorted(), id: \.self) { id in
                            HStack { Text(id == "telegram" ? "Telegram" : id); Spacer(); Text(model.statuses[id] ?? "").foregroundStyle(.secondary) }.font(.caption)
                        }
                    }
                    Text("Quality and format are reported by the source or inferred from the release name. Availability is checked when you select it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { environment.theme.backgroundGradient.ignoresSafeArea() }
            .tint(environment.theme.accent)
            .environment(\.defaultMinListRowHeight, 44)
            .searchable(text: $searchText, prompt: "Filter files, chats, quality…")
            .navigationTitle("Sources").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort by", selection: $sort) { ForEach(SourceResultSort.allCases) { Text($0.rawValue).tag($0) } }
                        Picker("Order", selection: $ascending) { Text("Ascending").tag(true); Text("Descending").tag(false) }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Sort sources")
                }
                ToolbarItem(placement: .primaryAction) { Button { scanID = UUID() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Rescan sources") }
            }
        }
        .onChange(of: VelagramStore.shared.hiddenCategories) { _, _ in scanID = UUID() }
        .onChange(of: VelagramStore.shared.busy) { _, busy in
            if !busy { scanID = UUID() }
        }
        .onChange(of: connectivity.isOffline) { _, offline in if offline { showDownloads = true } }
        .task(id: model.telegram) {
            for item in model.telegram {
                guard !Task.isCancelled else { return }
                guard let id = item.fileID else { continue }
                if store.files[id] == nil,
                   let response = try? await store.transport.call("getFile", ["file_id": .integer(Int64(id))], timeout: 5),
                   let file = TelegramFile(response) { store.files[id] = file }
                if (store.files[id]?.downloadedSize ?? 0) > 0 { downloads.track(item, request: request, store: store) }
            }
        }
        .confirmationDialog("Remove downloaded source?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove download", role: .destructive) {
                if let media = removal {
                    Task { do { try await downloads.deleteSource(media, store: store) } catch { deletionError = error.localizedDescription } }
                }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: { Text("Watch history and other sources are kept.") }
        .task(id: store.ready) { await downloads.refreshKnownFiles(for: request, store: store) }
        .alert("Could not delete source", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) { Button("OK") { deletionError = nil } } message: { Text(deletionError ?? "") }
        .navigationDestination(isPresented: $showDownloads) { DownloadsView() }
        .task(id: scanID.uuidString + String(connectivity.isOffline)) {
            downloads.reload()
            guard !connectivity.isOffline else { model.searching = false; showDownloads = true; return }
            let enrichment = Task { await environment.playbackContext(for: request) }
            defer { enrichment.cancel() }
            await model.scan(context: PlaybackLookupContext(request: request),
                             providers: await environment.registry.playbackProviders(),
                             store: store, pages: pages, enrichedContext: enrichment)
        }
        .sheet(isPresented: $signIn, onDismiss: { scanID = UUID() }) {
            NavigationStack { TelegramRootView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { signIn = false } } } }
        }
        .fullScreenCover(item: $model.selectedTelegram) { item in
            TelegramPlayerView(media: item, store: store, catalogRequest: request, library: environment.library, nextCatalogRequest: nextRequest)
        }
        .fullScreenCover(item: $model.selectedWeb) { selected in
            if selected.candidate.preference.providerID == "iptv" {
                IPTVSourcePlayerView(stream: selected, request: request, library: environment.library, nextRequest: nextRequest)
            } else { PlayerScreen(request: request, nextRequest: nextRequest, initialStream: selected) }
        }
    }
}

private struct SourceReleaseRow: View {
    let title: String
    let provider: String
    let metadata: StreamDisplayMetadata?
    var sourceIdentity: SourceIdentity = .telegram
    var chatName: String? = nil
    var messageDate: Date? = nil
    private var details: String {
        var values = provider == sourceIdentity.name ? [] : [provider]
        if let metadata {
            values += [metadata.quality, metadata.container, metadata.releaseType].compactMap { $0 }.filter { !$0.isEmpty }
            if let size = metadata.sizeBytes { values.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        }
        return values.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(3)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SourceBadge(identity: sourceIdentity)
                if !details.isEmpty { Text(details).font(.caption).foregroundStyle(Color.secondary) }
            }
            if let chatName { HStack(spacing: 6) { Image(systemName: "bubble.left.and.bubble.right"); Text(chatName) }.font(.caption).foregroundStyle(Color.secondary).lineLimit(2) }
            if let messageDate { HStack(spacing: 6) { Image(systemName: "calendar"); Text(messageDate.formatted(date: .abbreviated, time: .shortened)) }.font(.caption).foregroundStyle(Color.secondary) }
        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Shared badge for scanner rows and future source-selection surfaces.
struct SourceBadge: View {
    let identity: SourceIdentity
    private var tint: Color {
        switch identity.tint {
        case .cyan: .cyan
        case .purple: .purple
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        }
    }
    var body: some View {
        HStack(spacing: 5) { Image(systemName: identity.systemImage); Text(identity.name) }
            .font(.caption.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.5) }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Source: " + identity.name)
            .accessibilityIdentifier("source.badge." + identity.id)
    }
}

/// A full-size tap target with a determinate transfer ring and cancel action.
private struct SourceDownloadButton: View {
    @EnvironmentObject private var environment: AppEnvironment
    let active: Bool
    let saved: Bool
    let progress: DownloadTransferProgress?
    let action: () -> Void
    @State private var confirmingCancellation = false

    var body: some View {
        Button { if active { confirmingCancellation = true } else { action() } } label: {
            ZStack {
                if active {
                    Circle().stroke(environment.theme.accent.opacity(0.2), lineWidth: 2.5)
                    if let fraction = progress?.fraction {
                        Circle().trim(from: 0, to: fraction)
                            .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if progress?.fraction != nil {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold))
                    }
                } else {
                    Image(systemName: saved ? "checkmark.circle.fill" : "arrow.down.to.line")
                        .font(.system(size: 22, weight: .medium))
                }
            }
            .frame(width: 28, height: 28)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .alert("Cancel this download?", isPresented: $confirmingCancellation) {
            Button("Cancel download", role: .destructive, action: action)
            Button("Keep downloading", role: .cancel) {}
        }
        .disabled(saved && !active)
        .accessibilityLabel(active ? "Cancel download" : saved ? "Downloaded" : "Download")
        .accessibilityValue(active ? (progress?.fraction == nil ? "Preparing" : progress?.percentage ?? "") : "")
    }
}

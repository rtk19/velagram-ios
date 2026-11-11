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

    func scan(context: PlaybackLookupContext, providers: [any PlaybackProvider], store: TelegramStore, pages: Int) async {
        let token = UUID(); generation = token
        scanProgress = nil
        web = []; telegram = []; statuses = [:]; failure = nil; searching = true
        defer { if generation == token { searching = false } }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers + [VelagramStore.shared.iptvProvider()] {
                statuses[provider.id] = "Searching…"
                group.addTask { [weak self] in
                    do {
                        let results = try await withThrowingTaskGroup(of: [PlaybackCandidate].self) { timed in
                            timed.addTask { try await provider.candidates(for: context) }
                            timed.addTask { try await Task.sleep(for: .seconds(30)); throw AppError.noStream }
                            defer { timed.cancelAll() }
                            return try await timed.next() ?? []
                        }
                        await self?.receive(results, provider: provider.id, token: token)
                    } catch { await self?.status(provider.id, "Unavailable", token: token) }
                }
            }
            if store.ready {
                statuses["telegram"] = "Searching your Telegram media…"
                group.addTask { [weak self, transport = store.transport] in
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { timed in
                            timed.addTask { [weak self] in
                                try await TelegramCatalogSearch(transport: transport).search(context: context, pages: pages, onProgress: { [weak self] progress in
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
            } else { statuses["telegram"] = "Sign in to include Telegram" }
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
        statuses[provider] = values.isEmpty ? "No matches" : "\(values.count) sources"
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
    @Environment(\.dismiss) private var dismiss
    let request: PlaybackRequest
    let nextRequest: PlaybackRequest?
    @State private var model = TitleSourcesModel()
    @State private var pages = 4
    @State private var scanID = UUID()
    @State private var signIn = false
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
        TelegramReleaseGroup.group(model.telegram).compactMap { group in
            let locations = group.locations.filter { info($0).matches(searchText) }
            return locations.isEmpty ? nil : TelegramReleaseGroup(id: group.id, locations: locations)
        }.sorted { SourceResultInfo.ordered(info($0.representative), info($1.representative), by: sort, ascending: ascending) }
    }
    private var webResults: [PlaybackCandidate] {
        model.web.filter { info($0).matches(searchText) && (filter == "All" || (filter == "IPTV" ? $0.preference.providerID == "iptv" : $0.preference.providerID != "iptv")) }.sorted { SourceResultInfo.ordered(info($0), info($1), by: sort, ascending: ascending) }
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
            .sorted { SourceResultInfo.ordered(info($0), info($1), by: sort, ascending: ascending) }
    }
    private func telegramRow(_ group: TelegramReleaseGroup) -> some View {
        let item = group.representative
        return VStack(alignment: .leading, spacing: 8) {
            Button { model.selectedTelegram = item } label: {
                SourceReleaseRow(title: item.name, provider: "Telegram", metadata: TelegramCatalogMatching.metadata(item), chatName: store.chats[item.chatID]?.title ?? (model.searching ? "Loading chat…" : "Chat unavailable"), messageDate: item.date)
            }.buttonStyle(.plain).accessibilityHint("Play this release").accessibilityIdentifier("source.telegram.\(item.id)")
            if group.locations.count > 1 {
                Text("\(group.locations.count) copies").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func webRow(_ candidate: PlaybackCandidate) -> some View {
        Button { Task { await model.open(candidate) } } label: {
            HStack {
                SourceReleaseRow(title: candidate.preference.serverName, provider: candidate.providerName, metadata: candidate.displayMetadata)
                if model.openingID == candidate.id { ProgressView() }
            }
        }.buttonStyle(.plain).disabled(model.openingID != nil)
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.displayTitle).font(.title2.bold())
                    Text("Choose a source to play").foregroundStyle(.secondary)
                    Picker("Sources", selection: $filter) {
                        ForEach(["All", "Telegram", "Web", "IPTV"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    if model.searching { ProgressView("Scanning sources…") }
                    Toggle("Show scan progress", isOn: $showScanProgress).font(.subheadline)
                    if showScanProgress {
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
                Section("\(filter == "All" ? "Sources" : filter) · \(choices.count)") {
                    if showTelegram, !store.ready {
                        Button("Connect Telegram") { signIn = true }
                        Text("Sign in once to find matching files across your Telegram chats automatically.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(choices) { choice in
                        switch choice {
                        case .telegram(let group): telegramRow(group)
                        case .web(let candidate): webRow(candidate)
                        }
                    }
                    if choices.isEmpty, !model.searching { Text(searchText.isEmpty ? "No matching sources found." : "No results match this filter.").foregroundStyle(.secondary) }
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
            .scrollContentBackground(.hidden).background { Color(red: 0.035, green: 0.045, blue: 0.075).ignoresSafeArea() }
            .searchable(text: $searchText, prompt: "Filter files, chats, quality…")
            .navigationTitle("Sources").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort by", selection: $sort) { ForEach(SourceResultSort.allCases) { Text($0.rawValue).tag($0) } }
                        Picker("Order", selection: $ascending) { Text("Ascending").tag(true); Text("Descending").tag(false) }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Sort sources")
                }
                ToolbarItem(placement: .primaryAction) { Button { scanID = UUID() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Rescan sources") }
            }
        }
        .task(id: scanID) {
            await store.start()
            // Restoring TDLib authorization is asynchronous on an already signed-in device.
            for _ in 0..<40 where store.authorization == .null || store.authorization.type == "authorizationStateWaitTdlibParameters" {
                if Task.isCancelled { return }; try? await Task.sleep(for: .milliseconds(100))
            }
            let context = await environment.playbackContext(for: request)
            guard !Task.isCancelled else { return }
            await model.scan(context: context, providers: await environment.registry.playbackProviders(), store: store, pages: pages)
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
    var chatName: String? = nil
    var messageDate: Date? = nil
    private var details: String {
        guard let metadata else { return provider }
        var values = [provider]
        values += [metadata.quality, metadata.container, metadata.releaseType].compactMap { $0 }.filter { !$0.isEmpty }
        if let size = metadata.sizeBytes { values.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return values.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(3)
            Text(details).font(.caption).foregroundStyle(Color.secondary)
            if let chatName { Label(chatName, systemImage: "bubble.left.and.bubble.right").font(.caption).foregroundStyle(Color.secondary).lineLimit(2) }
            if let messageDate { Label(messageDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar").font(.caption).foregroundStyle(Color.secondary) }
        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
    }
}

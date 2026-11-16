import Foundation
import Observation
import Security

struct VelagramProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String = "person.crop.circle.fill"
}

struct DirectProgress: Codable {
    var position: Double
    var duration: Double
    var updated: Date
}

@MainActor @Observable final class VelagramStore {
    static let shared: VelagramStore = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["VELAGRAM_IPTV_GUIDE_FIXTURE"] == "1" || env["VELAGRAM_IPTV_PLAYER_FIXTURE"] == "1" || env["VELAGRAM_IPTV_CATEGORY_FIXTURE"] == "1" {
            let suite = "VelagramIPTVUITests"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return VelagramStore(defaults: defaults)
        }
        #endif
        return VelagramStore()
    }()
    var combineChannelSources = true { didSet { invalidateLiveLineup() } }
    var defaultChannelSources: [String: String] = [:]
    var channelRevision = 0
    var guideRevision = 0
    var channels: [LiveChannel] = [] { didSet { channelRevision &+= 1; sourceIndex = nil; favoriteSourceKeys = nil; invalidateLiveLineup() } }
    var iptvAccounts: [IPTVAccount] = []
    var iptvSeries: [IPTVSeries] = []
    var servers: [MediaServer] = []
    var favorites: Set<String> = [] { didSet { favoriteSourceKeys = nil } }
    var favoriteCategories: Set<String> = []
    var hiddenCategories: Set<String> = [] { didSet { invalidateLiveLineup() } }
    var hiddenChannelIDs: Set<String> = [] { didSet { invalidateLiveLineup() } }
    var channelOrder: [String] = [] { didSet { invalidateLiveLineup() } }
    var profiles: [VelagramProfile] = []
    var activeProfile: UUID?
    var guideDays: [Date] = [Calendar.current.startOfDay(for: .now)]
    var programs: [GuideProgram] = [] { didSet { guideDays = GuideDates.availableDays(in: programs); guideRevision &+= 1; programsByChannel = Dictionary(grouping: programs, by: \.channelID).mapValues { $0.sorted { $0.start < $1.start } } } }
    private var programsByChannel: [String: [GuideProgram]] = [:]
    var guideURL: String = ""
    var recent: [LiveChannel] = []
    var progress: [String: DirectProgress] = [:]
    var busy = false
    var importStatus: String?
    var importSummary: String?
    var guideLoading = false
    var guideStatus: String?
    var notice: String?
    // Cache storage must not emit observation changes while SwiftUI reads it.
    @ObservationIgnored private var cachedLiveChannels: [LiveChannel]?
    @ObservationIgnored private var sourceIndex: [String: [LiveChannel]]?
    @ObservationIgnored private var favoriteSourceKeys: Set<String>?
    private var liveLineupRevision = 0
    @ObservationIgnored private(set) var liveLineupBuildCount = 0
    @ObservationIgnored private(set) var sourceIndexBuildCount = 0

    private func invalidateLiveLineup() {
        cachedLiveChannels = nil
        liveLineupRevision &+= 1
    }
    private func indexedSources() -> [String: [LiveChannel]] {
        // Register a dependency even when returning cached, non-observable storage.
        _ = channelRevision
        if let sourceIndex { return sourceIndex }
        let index = Dictionary(grouping: (BundledChannels.load() + channels).filter { $0.contentKind == nil }, by: ChannelSources.key)
        sourceIndex = index
        sourceIndexBuildCount += 1
        return index
    }
    private let defaults: UserDefaults
    private var prefix: String { "velagram.profile.\(activeProfile?.uuidString ?? "default")." }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = Self.read([VelagramProfile].self, key: "velagram.profiles", defaults: defaults) ?? [VelagramProfile(name: "Me")]
        activeProfile = defaults.string(forKey: "velagram.activeProfile").flatMap(UUID.init(uuidString:)) ?? profiles.first?.id
        reload()
    }
    private static func read<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    func restorePreferences() {
        profiles = Self.read([VelagramProfile].self, key: "velagram.profiles", defaults: defaults) ?? [VelagramProfile(name: "Me")]
        activeProfile = defaults.string(forKey: "velagram.activeProfile").flatMap(UUID.init(uuidString:)) ?? profiles.first?.id
        reload()
    }
    func reload() {
        importSummary = nil; guideStatus = nil
        iptvAccounts = Self.read([IPTVAccount].self, key: prefix + "iptvAccounts", defaults: defaults) ?? []
        iptvSeries = Self.read([IPTVSeries].self, key: prefix + "iptvSeries", defaults: defaults) ?? []
        combineChannelSources = defaults.object(forKey: prefix + "combineChannelSources") as? Bool ?? true
        defaultChannelSources = Self.read([String: String].self, key: prefix + "defaultChannelSources", defaults: defaults) ?? [:]
        channels = Self.read([LiveChannel].self, key: prefix + "channels", defaults: defaults) ?? []
        servers = Self.read([MediaServer].self, key: prefix + "servers", defaults: defaults) ?? []
        favoriteCategories = Set(Self.read([String].self, key: prefix + "favoriteCategories", defaults: defaults) ?? [])
        hiddenCategories = Set(Self.read([String].self, key: prefix + "hiddenCategories", defaults: defaults) ?? [])
        hiddenChannelIDs = Set(Self.read([String].self, key: prefix + "hiddenChannelIDs", defaults: defaults) ?? [])
        channelOrder = Self.read([String].self, key: prefix + "channelOrder", defaults: defaults) ?? []
        favorites = Set(Self.read([String].self, key: prefix + "favorites", defaults: defaults) ?? [])
        recent = Self.read([LiveChannel].self, key: prefix + "recent", defaults: defaults) ?? []
        progress = Self.read([String: DirectProgress].self, key: prefix + "progress", defaults: defaults) ?? [:]
        guideURL = defaults.string(forKey: prefix + "guideURL") ?? ""
        for index in recent.indices where recent[index].group == "Files" {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Velagram/Files")
            recent[index].url = root.appending(path: recent[index].url.lastPathComponent)
        }
        programs = Self.read([GuideProgram].self, key: prefix + "programs", defaults: defaults) ?? []
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    func persist() {
        save(iptvAccounts, key: prefix + "iptvAccounts"); save(iptvSeries, key: prefix + "iptvSeries")
        defaults.set(combineChannelSources, forKey: prefix + "combineChannelSources")
        save(defaultChannelSources, key: prefix + "defaultChannelSources")
        save(channels, key: prefix + "channels"); save(servers, key: prefix + "servers")
        save(Array(favoriteCategories), key: prefix + "favoriteCategories")
        save(Array(hiddenChannelIDs), key: prefix + "hiddenChannelIDs")
        save(channelOrder, key: prefix + "channelOrder")
        save(Array(hiddenCategories), key: prefix + "hiddenCategories")
        save(Array(favorites), key: prefix + "favorites"); save(recent, key: prefix + "recent")
        save(progress, key: prefix + "progress"); save(profiles, key: "velagram.profiles")
        defaults.set(activeProfile?.uuidString, forKey: "velagram.activeProfile")
        defaults.set(guideURL, forKey: prefix + "guideURL")
    }
    func switchProfile(_ profile: VelagramProfile) { persist(); activeProfile = profile.id; reload(); persist() }
    func addProfile(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles.append(VelagramProfile(name: trimmed)); persist()
    }
    var visibleChannels: [LiveChannel] { channels.filter { !hiddenCategories.contains($0.group) } }
    var visibleSeries: [IPTVSeries] { iptvSeries.filter { !hiddenCategories.contains($0.group ?? "Series") } }
    var liveChannels: [LiveChannel] {
        _ = liveLineupRevision
        if let cachedLiveChannels { return cachedLiveChannels }
        let result = orderedChannels((BundledChannels.load() + visibleChannels).filter { $0.contentKind == nil && !hiddenCategories.contains($0.group) && !hiddenChannelIDs.contains($0.id) })
        cachedLiveChannels = result
        liveLineupBuildCount += 1
        return result
    }
    func orderedChannels(_ channels: [LiveChannel]) -> [LiveChannel] {
        let ranks = Dictionary(channelOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let displayed = combineChannelSources ? ChannelSources.grouped(channels) : channels
        return displayed.enumerated().sorted {
            let left = ranks[$0.element.id] ?? Int.max
            let right = ranks[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    func sources(for channel: LiveChannel) -> [LiveChannel] {
        guard combineChannelSources, channel.contentKind == nil, channel.catchupContext == nil else { return [channel] }
        let matches = indexedSources()[ChannelSources.key(channel), default: []].filter { !hiddenChannelIDs.contains($0.id) }
        return matches.isEmpty ? [channel] : matches
    }
    func defaultSource(for channel: LiveChannel) -> LiveChannel {
        let options = sources(for: channel)
        let preferred = defaultChannelSources[ChannelSources.key(channel)]
        var result = options.first { $0.id == preferred }
            ?? options.first { $0.name == ChannelSources.basicName($0.name) }
            ?? options.first ?? channel
        if combineChannelSources && channel.catchupContext == nil && channel.contentKind == nil {
            result.name = ChannelSources.basicName(channel.name)
        }
        return result
    }
    func setDefaultSource(_ source: LiveChannel, for channel: LiveChannel) {
        defaultChannelSources[ChannelSources.key(channel)] = source.id
        persist()
    }

    func applyChannelOrder(_ orderedScope: [String]) {
        let scope = Set(orderedScope)
        var replacement = orderedScope.makeIterator()
        let all = orderedChannels((BundledChannels.load() + channels).filter { $0.contentKind == nil }).map(\.id)
        var seen = Set<String>()
        let existing = (all + channelOrder).filter { seen.insert($0).inserted }
        channelOrder = existing.map { scope.contains($0) ? replacement.next() ?? $0 : $0 }
        channelOrder += orderedScope.filter { !seen.contains($0) }
        persist()
    }
    func moveChannelSelection(_ selected: Set<String>, in scope: [String], toOffset destination: Int) {
        let offsets = IndexSet(scope.indices.filter { selected.contains(scope[$0]) })
        guard !offsets.isEmpty else { return }
        let target = min(max(0, destination), scope.count)
        let moving = scope.filter { selected.contains($0) }
        var remaining = scope.filter { !selected.contains($0) }
        let insertion = target - offsets.filter { $0 < target }.count
        remaining.insert(contentsOf: moving, at: insertion)
        applyChannelOrder(remaining)
    }
    func matchesLiveSearch(_ channel: LiveChannel, query: String) -> Bool {
        query.isEmpty || channel.name.localizedCaseInsensitiveContains(query) ||
        channel.group.localizedCaseInsensitiveContains(query) ||
        schedule(channel).contains { $0.title.localizedCaseInsensitiveContains(query) }
    }
    func sortedCategories(_ categories: Set<String>) -> [String] {
        categories.filter { !hiddenCategories.contains($0) }.sorted {
            if favoriteCategories.contains($0) != favoriteCategories.contains($1) { return favoriteCategories.contains($0) }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
    func toggleCategoryFavorite(_ category: String) {
        if !favoriteCategories.insert(category).inserted { favoriteCategories.remove(category) }
        persist()
    }
    func hideCategory(_ category: String) { hiddenCategories.insert(category); persist() }
    func restoreCategory(_ category: String) { hiddenCategories.remove(category); persist() }
    func adjacentChannel(to channel: LiveChannel, direction: Int, in lineup: [LiveChannel]? = nil) -> LiveChannel? {
        let input = lineup ?? liveChannels
        let visible = (combineChannelSources ? ChannelSources.grouped(input) : input).filter { !hiddenCategories.contains($0.group) && $0.contentKind == nil && $0.isRadio == channel.isRadio }
        guard visible.count > 1, let index = visible.firstIndex(where: { $0.id == channel.id || (combineChannelSources && ChannelSources.key($0) == ChannelSources.key(channel)) }) else { return nil }
        return visible[(index + direction % visible.count + visible.count) % visible.count]
    }
    func isFavorite(_ channel: LiveChannel) -> Bool {
        if favorites.contains(channel.id) { return true }
        guard combineChannelSources, !favorites.isEmpty else { return false }
        _ = channelRevision
        if favoriteSourceKeys == nil {
            favoriteSourceKeys = Set((BundledChannels.load() + channels).filter { favorites.contains($0.id) && $0.contentKind == nil }.map(ChannelSources.key))
        }
        return favoriteSourceKeys?.contains(ChannelSources.key(channel)) == true
    }
    func toggleFavorite(_ channel: LiveChannel) {
        if isFavorite(channel) {
            favorites.subtract(sources(for: channel).map(\.id)); favorites.remove(channel.id)
        } else { favorites.insert(channel.id) }
        persist()
    }
    func record(_ channel: LiveChannel) {
        recent.removeAll { $0.id == channel.id || (combineChannelSources && ChannelSources.key($0) == ChannelSources.key(channel)) }; recent.insert(channel, at: 0)
        recent = Array(recent.prefix(50)); persist()
    }
    func removeRecent(_ channel: LiveChannel) {
        recent.removeAll { $0.id == channel.id }
        progress.removeValue(forKey: channel.id)
        persist()
    }
    func saveProgress(_ id: String, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0, position >= 0 else { return }
        progress[id] = DirectProgress(position: position, duration: duration, updated: .now); persist()
    }
    func importPlaylist(_ url: URL) async {
        guard !busy else { return }
        busy = true; importStatus = "Loading playlist…"
        defer { busy = false; importStatus = nil }
        do {
            let data = try await VelagramHTTP().data(url)
            guard let text = String(data: data, encoding: .utf8) else { throw VelagramNetworkError.invalidResponse }
            try importText(text, base: url)
            if !guideURL.isEmpty { await refreshGuide() }
        } catch { if !Task.isCancelled { notice = error.localizedDescription } }
    }
    func importText(_ text: String, base: URL? = nil) throws {
        let parsed = PlaylistParser.parse(text, relativeTo: base)
        guard !parsed.channels.isEmpty else { throw VelagramNetworkError.emptyPlaylist }
        var existing = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for channel in parsed.channels { existing[channel.id] = channel }
        channels = existing.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let guide = parsed.guideURL { guideURL = guide.absoluteString }
        persist(); notice = "Imported \(parsed.channels.count) channels."
    }
    func mediaServerProviders() -> [any PlaybackProvider] {
        servers.compactMap { server in
            guard let token = ServerTokenStore.load(server.id), !token.isEmpty else { return nil }
            return MediaServerPlaybackProvider(client: MediaServerClient(server: server, token: token))
        }
    }
    func iptvProvider() -> IPTVPlaybackProvider {
        let logins = iptvAccounts.reduce(into: [UUID: IPTVCredentials]()) { values, account in
            if let token = ServerTokenStore.load(account.id), let data = token.data(using: .utf8), let login = try? JSONDecoder().decode(IPTVCredentials.self, from: data) { values[account.id] = login }
        }
        return IPTVPlaybackProvider(entries: visibleChannels, accounts: iptvAccounts, series: visibleSeries, credentials: logins, programs: programs)
    }
    func refreshIPTVAccounts() async {
        let accounts = iptvProvider()
        for account in accounts.accounts {
            guard !Task.isCancelled else { return }
            if let login = accounts.credentials[account.id] {
                await importXtream(server: account.server, username: login.username, password: login.password)
            }
        }
    }
    func importXtream(server inputServer: URL, username: String, password: String) async {
        var components = URLComponents(url: inputServer, resolvingAgainstBaseURL: false)!
        components.query = nil; components.fragment = nil
        if ["get.php", "player_api.php", "xmltv.php"].contains(inputServer.lastPathComponent.lowercased()) {
            components.path = inputServer.deletingLastPathComponent().path
        }
        let server = components.url!
        guard !busy else { return }
        busy = true; importSummary = nil
        defer { busy = false; importStatus = nil }
        let profile = activeProfile
        let account = iptvAccounts.first { $0.server == server && ServerTokenStore.load($0.id).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(IPTVCredentials.self, from: $0) }?.username == username }
            ?? IPTVAccount(id: UUID(), server: server, name: server.host ?? "Xtream")
        let login = IPTVCredentials(username: username, password: password)
        let client = IPTVOnDemandClient(account: account, credentials: login)
        do {
            try ServerTokenStore.save(String(decoding: JSONEncoder().encode(login), as: UTF8.self), id: account.id)
            var incomplete = false
            var imported = false
            importStatus = "Loading live channels and categories…"
            do {
                let live = try await client.liveChannels(excluding: hiddenCategories)
                guard activeProfile == profile else { return }
                guard !live.isEmpty || !hiddenCategories.isEmpty else { throw VelagramNetworkError.emptyPlaylist }
                channels.removeAll {
                    ($0.accountID == account.id && $0.contentKind == nil && !hiddenCategories.contains($0.group)) ||
                    ($0.url.host == server.host && ["get.php", "player_api.php", "xmltv.php"].contains($0.url.lastPathComponent.lowercased()))
                }
                if !iptvAccounts.contains(where: { $0.id == account.id }) { iptvAccounts.append(account) }
                mergeChannels(live)
                imported = true
            } catch { incomplete = true }
            guard activeProfile == profile, !Task.isCancelled else { return }
            guideURL = XtreamClient.guide(server: server, username: username, password: password).absoluteString
            importStatus = "Loading movies… Live channels are ready to browse. Search results will expand as titles arrive."
            do {
                let movies = try await client.movies(excluding: hiddenCategories)
                guard activeProfile == profile else { return }
                imported = true
                var known = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                for movie in movies { known[movie.id] = movie }
                channels = known.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                persist()
            } catch { incomplete = true }
            guard activeProfile == profile, !Task.isCancelled else { return }
            importStatus = "Loading series… Movies are available in the library and scanner."
            do { let shows = try await client.series(excluding: hiddenCategories); guard activeProfile == profile else { return }; imported = true; iptvSeries.removeAll { $0.accountID == account.id && !hiddenCategories.contains($0.group ?? "Series") }; iptvSeries += shows }
            catch { incomplete = true }
            guard activeProfile == profile else { return }
            guard imported else { throw VelagramNetworkError.invalidResponse }
            if !iptvAccounts.contains(where: { $0.id == account.id }) { iptvAccounts.append(account) }
            persist()
            importStatus = "Loading XMLTV program guide…"
            await refreshGuide()
            guard activeProfile == profile, !Task.isCancelled else { return }
            notice = incomplete ? "Connection partly loaded. Live TV, movies, or series could not be loaded; reconnect to retry." : "Connected live TV, movies, and series. On-demand titles are included in source scans."
            importSummary = notice
        } catch { if !Task.isCancelled && activeProfile == profile {
            notice = "Could not connect to the IPTV server. Check the address and login."
            importSummary = notice
        } }
    }
    private func mergeChannels(_ entries: [LiveChannel]) {
        var known = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for entry in entries { known[entry.id] = entry }
        channels = known.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }
    func refreshGuide() async {
        guard !guideURL.isEmpty, !guideLoading else { return }
        guideLoading = true
        defer { guideLoading = false }
        let address = guideURL
        let profile = activeProfile
        do {
            let data = try await VelagramHTTP().data(VelagramHTTP.url(address))
            let visibleIDs = Set(liveChannels.compactMap(\.guideID))
            let excluded = Set(channels.filter { hiddenCategories.contains($0.group) }.compactMap(\.guideID)).subtracting(visibleIDs)
            let parsed = try await Task.detached(priority: .utility) { try XMLTVParser.parse(data, excludingChannelIDs: excluded) }.value
            guard profile == activeProfile, address == guideURL else { return }
            let previous = programs
            let channels = liveChannels
            let merged = await Task.detached(priority: .utility) {
                GuideDates.retainingCatchupHistory(previous, incoming: parsed, channels: channels)
            }.value
            guard profile == activeProfile, address == guideURL, !Task.isCancelled else { return }
            programs = merged
            save(merged, key: prefix + "programs")
            guideStatus = "Guide updated · \(parsed.count) programs"
        } catch { if !Task.isCancelled { guideStatus = "Guide could not load. Refresh to retry." } }
    }
    func schedule(_ channel: LiveChannel) -> [GuideProgram] {
        guard !hiddenCategories.contains(channel.group), let id = channel.guideID, !id.isEmpty else { return [] }
        return programsByChannel[id] ?? []
    }
    func now(_ channel: LiveChannel, at date: Date = .now) -> GuideProgram? {
        schedule(channel).first { $0.start <= date && $0.end > date }
    }
    func nextCatchup(after replay: LiveChannel) -> LiveChannel? {
        guard let context = replay.catchupContext,
              let channel = liveChannels.first(where: { $0.id == context.channelID }),
              let next = context.nextProgram(in: schedule(channel)) else { return nil }
        return catchup(channel, program: next)
    }
    func catchup(_ channel: LiveChannel, program: GuideProgram) -> LiveChannel? {
        guard let days = channel.archiveDays, days > 0, program.end <= .now,
              program.start >= Date.now.addingTimeInterval(-Double(days) * 86400),
              let account = iptvAccounts.first(where: { $0.id == channel.accountID }),
              let token = ServerTokenStore.load(account.id),
              let login = try? JSONDecoder().decode(IPTVCredentials.self, from: Data(token.utf8)) else { return nil }
        return IPTVOnDemandClient(account: account, credentials: login).catchup(channel, program: program)
    }

}

enum ServerTokenStore {
    static func save(_ token: String, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.refael.Velagram.servers", kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func delete(_ id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.refael.Velagram.servers", kSecAttrAccount as String: id.uuidString] as CFDictionary)
    }
    static func load(_ id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.refael.Velagram.servers", kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

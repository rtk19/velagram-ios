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
    static let shared = VelagramStore()
    var channels: [LiveChannel] = []
    var iptvAccounts: [IPTVAccount] = []
    var iptvSeries: [IPTVSeries] = []
    var servers: [MediaServer] = []
    var favorites: Set<String> = []
    var profiles: [VelagramProfile] = []
    var activeProfile: UUID?
    var programs: [GuideProgram] = []
    var guideURL: String = ""
    var recent: [LiveChannel] = []
    var progress: [String: DirectProgress] = [:]
    var busy = false
    var notice: String?
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
        iptvAccounts = Self.read([IPTVAccount].self, key: prefix + "iptvAccounts", defaults: defaults) ?? []
        iptvSeries = Self.read([IPTVSeries].self, key: prefix + "iptvSeries", defaults: defaults) ?? []
        channels = Self.read([LiveChannel].self, key: prefix + "channels", defaults: defaults) ?? []
        servers = Self.read([MediaServer].self, key: prefix + "servers", defaults: defaults) ?? []
        favorites = Set(Self.read([String].self, key: prefix + "favorites", defaults: defaults) ?? [])
        recent = Self.read([LiveChannel].self, key: prefix + "recent", defaults: defaults) ?? []
        progress = Self.read([String: DirectProgress].self, key: prefix + "progress", defaults: defaults) ?? [:]
        guideURL = defaults.string(forKey: prefix + "guideURL") ?? ""
        for index in recent.indices where recent[index].group == "Files" {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Velagram/Files")
            recent[index].url = root.appending(path: recent[index].url.lastPathComponent)
        }
        programs = []
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    func persist() {
        save(iptvAccounts, key: prefix + "iptvAccounts"); save(iptvSeries, key: prefix + "iptvSeries")
        save(channels, key: prefix + "channels"); save(servers, key: prefix + "servers")
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
    func toggleFavorite(_ channel: LiveChannel) {
        if !favorites.insert(channel.id).inserted { favorites.remove(channel.id) }
        persist()
    }
    func record(_ channel: LiveChannel) {
        recent.removeAll { $0.id == channel.id }; recent.insert(channel, at: 0)
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
        busy = true; defer { busy = false }
        do {
            let data = try await VelagramHTTP().data(url)
            guard let text = String(data: data, encoding: .utf8) else { throw VelagramNetworkError.invalidResponse }
            try importText(text, base: url)
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
    func iptvProvider() -> IPTVPlaybackProvider {
        let logins = iptvAccounts.reduce(into: [UUID: IPTVCredentials]()) { values, account in
            if let token = ServerTokenStore.load(account.id), let data = token.data(using: .utf8), let login = try? JSONDecoder().decode(IPTVCredentials.self, from: data) { values[account.id] = login }
        }
        return IPTVPlaybackProvider(entries: channels, accounts: iptvAccounts, series: iptvSeries, credentials: logins, programs: programs)
    }
    func importXtream(server: URL, username: String, password: String) async {
        busy = true; defer { busy = false }
        let account = iptvAccounts.first { $0.server == server && ServerTokenStore.load($0.id).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(IPTVCredentials.self, from: $0) }?.username == username }
            ?? IPTVAccount(id: UUID(), server: server, name: server.host ?? "Xtream")
        let login = IPTVCredentials(username: username, password: password)
        let client = IPTVOnDemandClient(account: account, credentials: login)
        do {
            try ServerTokenStore.save(String(decoding: JSONEncoder().encode(login), as: UTF8.self), id: account.id)
            var incomplete = false
            var imported = false
            do {
                let data = try await VelagramHTTP().data(XtreamClient.playlist(server: server, username: username, password: password))
                try importText(String(decoding: data, as: UTF8.self), base: server)
                imported = true
            } catch { incomplete = true }
            guideURL = XtreamClient.guide(server: server, username: username, password: password).absoluteString
            do {
                let movies = try await client.movies(); imported = true
                var known = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                for movie in movies { known[movie.id] = movie }
                channels = known.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch { incomplete = true }
            do { let shows = try await client.series(); imported = true; iptvSeries.removeAll { $0.accountID == account.id }; iptvSeries += shows }
            catch { incomplete = true }
            guard imported else { throw VelagramNetworkError.invalidResponse }
            if !iptvAccounts.contains(where: { $0.id == account.id }) { iptvAccounts.append(account) }
            persist()
            notice = incomplete ? "Imported playlist. Some on-demand catalogs were unavailable; reconnect to retry." : "Connected live TV, movies, and series. On-demand titles are included in source scans."
        } catch { if !Task.isCancelled { notice = "Could not connect to the IPTV server. Check the address and login." } }
    }
    func refreshGuide() async {
        guard !guideURL.isEmpty else { return }
        do { programs = try XMLTVParser.parse(try await VelagramHTTP().data(VelagramHTTP.url(guideURL))) }
        catch { if !Task.isCancelled { notice = error.localizedDescription } }
    }
    func schedule(_ channel: LiveChannel) -> [GuideProgram] {
        programs.filter { $0.channelID == channel.guideID && $0.end > .now }.sorted { $0.start < $1.start }
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

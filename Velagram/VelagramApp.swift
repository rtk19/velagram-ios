// Adapted for Velagram iOS, November 2026. See NOTICE and LICENSE.
import SwiftUI
import UIKit

enum PlayerOrientationPreference: String, CaseIterable, Identifiable {
    case autoRotate
    case landscapeOnly

    var id: Self { self }

    var name: String {
        switch self {
        case .autoRotate: "Auto-Rotate"
        case .landscapeOnly: "Landscape Only"
        }
    }

    var supportedOrientations: UIInterfaceOrientationMask {
        switch self {
        case .autoRotate: .allButUpsideDown
        case .landscapeOnly: [.landscapeLeft, .landscapeRight]
        }
    }
}

@MainActor
final class AppOrientationController {
    static let shared = AppOrientationController()

    private(set) var supportedOrientations: UIInterfaceOrientationMask = .portrait

    private init() {}

    func beginPlayback(using preference: PlayerOrientationPreference) {
        updateSupportedOrientations(
            preference.supportedOrientations,
            requestsGeometryUpdate: preference == .landscapeOnly
        )
    }

    func endPlayback() {
        updateSupportedOrientations(.portrait, requestsGeometryUpdate: true)
    }

    private func updateSupportedOrientations(
        _ orientations: UIInterfaceOrientationMask,
        requestsGeometryUpdate: Bool
    ) {
        supportedOrientations = orientations

        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            guard requestsGeometryUpdate else { continue }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationController.shared.supportedOrientations
    }
}

@main
struct VelagramApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.environment["VELAGRAM_REAL_CATCHUP_UI"] == "1" { RealCatchupTestHost() }
                else if ProcessInfo.processInfo.environment["VELAGRAM_OFFLINE_LIBRARY_FIXTURE"] == "1" { OfflineLibraryTestHost() }
                else if ProcessInfo.processInfo.environment["VELAGRAM_IPTV_GUIDE_FIXTURE"] == "1" || ProcessInfo.processInfo.environment["VELAGRAM_IPTV_CATEGORY_FIXTURE"] == "1" { IPTVGuideTestHost() }
                else if ProcessInfo.processInfo.environment["VELAGRAM_BASELINE_KIND"] != nil { PlaybackBaseline() }
                else if let fixture = PlayerTestLaunch.media {
                    if ProcessInfo.processInfo.environment["VELAGRAM_IPTV_PLAYER_FIXTURE"] == "1" { IPTVPlayerTestHost(media: fixture) }
                    else if ProcessInfo.processInfo.environment["VELAGRAM_PLAYER_TEST_DIRECT"] == "1" { DirectPlayerTestHost(media: fixture) }
                    else { TelegramPlayerView(media: fixture, store: PlayerTestLaunch.store, rememberPlayback: false) }
                } else { RootView().modifier(DebugPlaybackRetry()).task { await TelegramStore.shared.start() } }
                #else
                RootView().task { await TelegramStore.shared.start() }
                #endif
            }
                .environmentObject(environment)
                .environmentObject(environment.library)
                .environmentObject(environment.sourceLookup)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, TelegramStore.shared.ready { Task { await CacheManager.shared.maintain(transport: TelegramStore.shared.transport) } }
                }
        }
    }
}

#if DEBUG
private struct DebugPlaybackRetry: ViewModifier {
    @State private var media: TelegramMedia?
    func body(content: Content) -> some View {
        content.task {
            guard ProcessInfo.processInfo.environment["VELAGRAM_RETRY_LAST_TELEGRAM"] == "1" else { return }
            let store = TelegramStore.shared
            await store.start()
            for _ in 0..<100 where !store.ready { try? await Task.sleep(for: .milliseconds(100)) }
            if store.ready { media = store.recentMedia.first }
        }.fullScreenCover(item: $media) { TelegramPlayerView(media: $0, store: .shared) }
    }
}
private struct DirectPlayerTestHost: View {
    let media: TelegramMedia
    @State private var presented = true
    var body: some View {
        Text("Playback closed").fullScreenCover(isPresented: $presented) {
            DirectPlayerView(channel: LiveChannel(id: "fixture", name: "Fixture", url: media.remoteURL!, group: "Test"))
        }
    }
}
@MainActor private enum PlayerTestLaunch {
    static let store = TelegramStore(transport: TDLibTransport.shared, defaults: UserDefaults(suiteName: "VelagramPlayerUITests")!)
    static let media: TelegramMedia? = {
        guard let encoded = ProcessInfo.processInfo.environment["VELAGRAM_PLAYER_TEST_FIXTURE"], let data = Data(base64Encoded: encoded) else { return nil }
        let ext = ProcessInfo.processInfo.environment["VELAGRAM_PLAYER_TEST_DIRECT"] == "1" || ProcessInfo.processInfo.environment["VELAGRAM_PLAYER_TEST_CONTAINER"] == "mp4" ? "mp4" : "mkv"
        let url = FileManager.default.temporaryDirectory.appending(path: "PlayerPreview.S01E01." + ext)
        guard (try? data.write(to: url)) != nil else { return nil }
        return TelegramMedia(chatID: -9001, messageID: -9001, fileID: nil, name: url.lastPathComponent, caption: "Generated playback fixture", date: .now,
            size: Int64(data.count), duration: 30, mimeType: "video/x-matroska", thumbnailFileID: nil, kind: .video, remoteURL: url)
    }()
}
#endif

#if DEBUG
private struct RealCatchupTestHost: View {
    @State private var replay: PlayableStream?
    @State private var unavailable = false
    var body: some View {
        Button("Open real catch-up") {
            let store = VelagramStore.shared
            let channels = store.liveChannels.filter { $0.supportsCatchup }
            if let channel = channels.first(where: { $0.name.contains("ספורט 5") }) ?? channels.first,
               let program = store.schedule(channel).last(where: { $0.end < .now && $0.end.timeIntervalSince($0.start) > 7200 && store.catchup(channel, program: $0) != nil }),
               let entry = store.catchup(channel, program: program) {
                replay = OnDemandLibraryView.playable(entry)
            } else { unavailable = true }
        }
        .overlay(alignment: .bottom) { if unavailable { Text("No real archive available") } }
        .fullScreenCover(item: $replay) { IPTVSourcePlayerView(stream: $0) }
    }
}

private struct IPTVGuideTestHost: View {
    @State private var ready = false
    var body: some View {
        Group {
            if ready { NavigationStack {
                if ProcessInfo.processInfo.environment["VELAGRAM_IPTV_CATEGORY_FIXTURE"] == "1" { LiveView() } else { ProgramGuideView() }
            } }
            else { ProgressView().task { seed(); ready = true } }
        }
    }
    private func seed() {
        let store = VelagramStore.shared
        store.hiddenCategories = []; store.favoriteCategories = []
        store.guideURL = ""
        let start = Calendar.current.startOfDay(for: .now)
        store.channels = (0..<727).map { index in
            LiveChannel(id: "fixture:\(index)", name: String(format: "Channel %03d", index), url: URL(string: "https://example.invalid/\(index).m3u8")!, group: index % 2 == 0 ? "News" : "Entertainment", guideID: "fixture:\(index)")
        }
        var programs: [GuideProgram] = []
        for channel in store.channels {
            for slot in 0..<48 {
                let from = start.addingTimeInterval(Double(slot) * 1800)
                let to = from.addingTimeInterval(1800)
                let title = slot % 2 == 0 ? "World news" : "Documentary"
                programs.append(GuideProgram(channelID: channel.guideID!, title: title, summary: "Sample program", start: from, end: to))
            }
        }
        if ProcessInfo.processInfo.environment["VELAGRAM_IPTV_DATE_RANGE_FIXTURE"] == "1" {
            for offset in [-14, -1, 15] {
                let from = Calendar.current.date(byAdding: .day, value: offset, to: start)!
                programs.append(GuideProgram(channelID: "fixture:0", title: "Guide day \(offset)", summary: "", start: from, end: from.addingTimeInterval(3600)))
            }
        }
        store.programs = programs
        if let media = PlayerTestLaunch.media { store.channels[0].url = media.remoteURL! }
        store.channels[0].archiveDays = 3
        store.programs.append(GuideProgram(channelID: "fixture:0", title: "Portland highlights", summary: "Yesterday’s basketball", start: Date.now.addingTimeInterval(-7200), end: Date.now.addingTimeInterval(-3600)))
    }
}
#endif

#if DEBUG
private struct IPTVPlayerTestHost: View {
    let media: TelegramMedia
    @State private var ready = false
    @State private var presented = true
    var body: some View {
        Text("Playback closed")
            .task {
                let store = VelagramStore.shared
                let first = LiveChannel(id: "fixture:one", name: "News One", url: media.remoteURL!, group: "News", guideID: "one")
                let hidden = LiveChannel(id: "fixture:hidden", name: "Hidden TV", url: media.remoteURL!, group: "Hidden", guideID: "hidden")
                let second = LiveChannel(id: "fixture:two", name: "News Two", url: media.remoteURL!, group: "News", guideID: "two")
                store.channels = [first, hidden, second]; store.hiddenCategories = ["Hidden"]
                if ProcessInfo.processInfo.environment["VELAGRAM_IPTV_SOURCES_FIXTURE"] == "1" {
                    var backup = first
                    backup.id = "fixture:one-backup"; backup.name = "News One - (גיבוי 2)"
                    store.channels.append(backup)
                    backup.id = "fixture:one-backup3"; backup.name = "News One - (גיבוי 3)"
                    store.channels.append(backup)
                }
                store.programs = [GuideProgram(channelID: "one", title: "Morning news", summary: "", start: Date.now.addingTimeInterval(-1800), end: Date.now.addingTimeInterval(1800)), GuideProgram(channelID: "two", title: "Sports roundup", summary: "", start: Date.now.addingTimeInterval(-1800), end: Date.now.addingTimeInterval(1800))]
                let now = Date.now
                let history = (1...20).map { index in
                    GuideProgram(channelID: "one", title: "Earlier program \(index)", summary: "", start: now.addingTimeInterval(-1800 - Double(index) * 1800), end: now.addingTimeInterval(-1800 - Double(index - 1) * 1800))
                }
                store.programs += history
                ready = true
            }
            .fullScreenCover(isPresented: Binding(get: { ready && presented }, set: { presented = $0 })) {
                DirectPlayerView(channel: VelagramStore.shared.channels[0], lineup: VelagramStore.shared.channels)
            }
    }
}
#endif

#if DEBUG
/// Deterministic populated library for simulator UI checks, without network or Telegram.
private struct OfflineLibraryTestHost: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var ready = false
    var body: some View {
        Group {
            if ready { NavigationStack { DownloadsView(reloadOnAppear: false) } }
            else { ProgressView() }
        }.task {
            let downloads = TelegramDownloads.shared
            let show = MediaItem(id: "offline-fixture", providerID: "fixture", kind: .series, title: "The Offline Collection", tmdbID: -901)
            let movie = MediaItem(id: "offline-movie", providerID: "fixture", kind: .movie, title: "A Film for the Journey", tmdbID: -902)
            let root = FileManager.default.temporaryDirectory.appending(path: "OfflineLibraryFixture")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: TelegramSavedDownload.directory, withIntermediateDirectories: true)
            var records: [TelegramSavedDownload] = []
            for number in 1...3 {
                let episode = number < 3 ? MediaEpisode(id: "fixture-\(number)", providerID: "fixture", showID: show.id, seasonNumber: 1, number: number, title: "Episode \(number)", overview: "Available without a connection", posterURL: nil) : nil
                let title = number < 3 ? show : movie
                let media = TelegramMedia(chatID: -901, messageID: Int64(number), fileID: number == 2 ? 9002 : nil, name: number < 3 ? "The.Offline.Collection.S01E0\(number).1080p.mp4" : title.title + ".mp4", caption: "Fixture", date: .now, size: 450_000_000, duration: 1800, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: nil)
                let cached = number == 2
                let filename = "offline-fixture-\(number).mp4"
                let url = cached ? root.appending(path: filename) : TelegramSavedDownload.directory.appending(path: filename)
                try? Data([1]).write(to: url)
                records.append(TelegramSavedDownload(media: media, filename: cached ? "" : filename, savedAt: .now, catalogMedia: title, catalogEpisode: episode, cachedPath: cached ? url.path : nil))
                if number == 1 { library.updateProgress(request: PlaybackRequest(media: show, episode: episode), position: 300, duration: 1800) }
            }
            let first = records[0]
            let alias = TelegramMedia(chatID: -902, messageID: 101, fileID: 9101, name: first.media.name, caption: "Duplicate message location", date: .now, size: first.media.size, duration: 1800, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: nil)
            let cachedURL = root.appending(path: "duplicate.mp4"); try? Data([1]).write(to: cachedURL)
            records.append(TelegramSavedDownload(media: alias, filename: "", savedAt: .now, catalogMedia: show, catalogEpisode: first.catalogEpisode, cachedPath: cachedURL.path))
            let alternate = TelegramMedia(chatID: -903, messageID: 102, fileID: 9102, name: "The.Offline.Collection.S01E01.720p.mp4", caption: "Different release", date: .now, size: 200_000_000, duration: 1800, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: nil)
            let alternateURL = root.appending(path: "alternate.mp4"); try? Data([1]).write(to: alternateURL)
            records.append(TelegramSavedDownload(media: alternate, filename: "", savedAt: .now, catalogMedia: show, catalogEpisode: first.catalogEpisode, cachedPath: alternateURL.path))
            downloads.webActive = ["fixture-transfer"]
            downloads.webTitles["fixture-transfer"] = "The.Offline.Collection.S01E02.720p.mp4"
            downloads.webRequests["fixture-transfer"] = PlaybackRequest(media: show, episode: records[1].catalogEpisode)
            downloads.webProviders["fixture-transfer"] = "Fixture server"
            let time = ProcessInfo.processInfo.systemUptime
            downloads.updateProgress("web:fixture-transfer", received: 126_000_000, total: 512_000_000, now: time - 1)
            downloads.updateProgress("web:fixture-transfer", received: 128_000_000, total: 512_000_000, now: time)
            downloads.saved = records
            ready = true
        }
    }
}
#endif

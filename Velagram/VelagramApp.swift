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
                if ProcessInfo.processInfo.environment["VELAGRAM_BASELINE_KIND"] != nil { PlaybackBaseline() }
                else if let fixture = PlayerTestLaunch.media {
                    if ProcessInfo.processInfo.environment["VELAGRAM_PLAYER_TEST_DIRECT"] == "1" { DirectPlayerTestHost(media: fixture) }
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

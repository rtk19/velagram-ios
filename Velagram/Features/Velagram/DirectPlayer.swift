import SwiftUI
import AVKit

@MainActor final class DirectPlaybackSession: ObservableObject {
    let player: AVPlayer
    let channel: LiveChannel
    @Published var failure: String?
    @Published var loading = true
    nonisolated(unsafe) private var observer: Any?
    private var status: NSKeyValueObservation?
    private var securityURL: URL?
    private var resumed = false
    private var cacheLease: CacheUsage.Lease?
    init(channel: LiveChannel) {
        self.channel = channel
        player = AVPlayer()
    }
    func start() async {
        do {
            if cacheLease == nil { cacheLease = try await CacheUsage.shared.waitForReader() }
            let resolved = try await LiveResolver().resolve(channel)
            try Task.checkCancellation()
            configure(resolved)
        } catch { if !Task.isCancelled { loading = false; failure = error.localizedDescription } }
    }
    private func configure(_ channel: LiveChannel) {
        if channel.url.isFileURL, channel.url.startAccessingSecurityScopedResource() { securityURL = channel.url }
        let asset = AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.allowsExternalPlayback = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.status == .failed {
                    self.loading = false
                    self.failure = item.error?.localizedDescription ?? "This stream could not be played. Its format or authorization may require another player."
                } else if item.status == .readyToPlay, !self.resumed {
                    self.loading = false
                    self.resumed = true
                    if item.duration.seconds.isFinite, item.duration.seconds > 0,
                       let saved = VelagramStore.shared.progress[channel.id], saved.position < item.duration.seconds - 15 {
                        await self.player.seek(to: CMTime(seconds: saved.position, preferredTimescale: 600))
                    }
                    self.player.play()
                }
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                VelagramStore.shared.saveProgress(channel.id, position: time.seconds, duration: self.player.currentItem?.duration.seconds ?? 0)
            }
        }
        VelagramStore.shared.record(channel)
        AppOrientationController.shared.beginPlayback(using: .autoRotate)
    }
    func stop() {
        cacheLease?.release(); cacheLease = nil
        VelagramStore.shared.saveProgress(channel.id, position: player.currentTime().seconds, duration: player.currentItem?.duration.seconds ?? 0)
        player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        status?.invalidate(); status = nil
        if let securityURL { securityURL.stopAccessingSecurityScopedResource(); self.securityURL = nil }
        AppOrientationController.shared.endPlayback()
    }
    deinit { if let observer { player.removeTimeObserver(observer) }; securityURL?.stopAccessingSecurityScopedResource() }
}

struct DirectPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: DirectPlaybackSession
    init(channel: LiveChannel) { _session = StateObject(wrappedValue: DirectPlaybackSession(channel: channel)) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            DirectPlayerController(player: session.player, onDismiss: { dismiss() }).ignoresSafeArea()
            if session.loading {
                ProgressView("Opening stream…").padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let failure = session.failure {
                VStack(spacing: 16) {
                    ContentUnavailableView("Playback unavailable", systemImage: "exclamationmark.tv", description: Text(failure))
                    Button("Close player") { dismiss() }.buttonStyle(.borderedProminent)
                }.padding().background(.black.opacity(0.9))
            }

            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44).modifier(PlayerGlass(circle: true)) }
                .accessibilityLabel("Close player").accessibilityIdentifier("live.close").padding()
        }.task { await session.start() }.onDisappear { session.stop() }.preferredColorScheme(.dark)
    }
}

private struct DirectPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }
    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.onDismiss() }
        }
    }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = DismissibleDirectController()
        controller.close = onDismiss
        controller.delegate = context.coordinator
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) { controller.player = nil }
}

private final class DismissibleDirectController: AVPlayerViewController {
    var close: (() -> Void)?
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        close?(); completion?()
    }
}

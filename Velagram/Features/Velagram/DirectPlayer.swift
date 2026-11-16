import SwiftUI
import AVKit

@MainActor final class DirectPlaybackSession: ObservableObject {
    let player: AVPlayer
    @Published var channel: LiveChannel
    @Published var failure: String?
    @Published var loading = true
    nonisolated(unsafe) private var observer: Any?
    private var status: NSKeyValueObservation?
    private var securityURL: URL?
    private var resumed = false
    private var playingChannel: LiveChannel?
    private var cacheLease: CacheUsage.Lease?
    init(channel: LiveChannel) {
        self.channel = channel
        player = AVPlayer()
    }
    func start() async {
        stop(endingPresentation: false)
        loading = true; failure = nil; resumed = false
        do {
            if cacheLease == nil { cacheLease = try await CacheUsage.shared.waitForReader() }
            let resolved = try await LiveResolver().resolve(channel)
            try Task.checkCancellation()
            try await configure(resolved)
        } catch { if !Task.isCancelled { loading = false; failure = error.localizedDescription } }
    }
    private func configure(_ channel: LiveChannel) async throws {
        playingChannel = channel
        if channel.url.isFileURL, channel.url.startAccessingSecurityScopedResource() { securityURL = channel.url }
        let asset = AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
        var playbackAsset: AVAsset = asset
        #if DEBUG
        // Model a continuous live feed in UI tests; the bundled sample is only four seconds long.
        if ProcessInfo.processInfo.environment["VELAGRAM_IPTV_PLAYER_FIXTURE"] == "1" {
            let composition = AVMutableComposition()
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if range.duration.seconds.isFinite, range.duration.seconds > 0 {
                for _ in 0..<60 {
                    try Task.checkCancellation()
                    try await composition.insertTimeRange(range, of: asset, at: composition.duration)
                }
                playbackAsset = composition
            }
        }
        #endif
        try Task.checkCancellation()
        let item = AVPlayerItem(asset: playbackAsset)
        player.replaceCurrentItem(with: item)
        updateMetadata()
        player.allowsExternalPlayback = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
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
    func updateMetadata() {
        guard let item = player.currentItem else { return }
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = channel.name as NSString
        title.extendedLanguageTag = "und"
        let subtitle = AVMutableMetadataItem()
        subtitle.identifier = .iTunesMetadataTrackSubTitle
        subtitle.value = (VelagramStore.shared.now(channel)?.title ?? channel.group) as NSString
        subtitle.extendedLanguageTag = "und"
        item.externalMetadata = [title, subtitle]
    }
    func stop(endingPresentation: Bool = true) {
        cacheLease?.release(); cacheLease = nil
        if let playingChannel { VelagramStore.shared.saveProgress(playingChannel.id, position: player.currentTime().seconds, duration: player.currentItem?.duration.seconds ?? 0) }
        playingChannel = nil
        player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        status?.invalidate(); status = nil
        if let securityURL { securityURL.stopAccessingSecurityScopedResource(); self.securityURL = nil }
        if endingPresentation { AppOrientationController.shared.endPlayback() }
    }
    deinit { if let observer { player.removeTimeObserver(observer) }; securityURL?.stopAccessingSecurityScopedResource() }
}

struct DirectPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: DirectPlaybackSession
    @State private var store = VelagramStore.shared
    @State private var showGuide = false
    @State private var controlsVisible = false
    @State private var replay: PlayableStream?
    let lineup: [LiveChannel]?
    init(channel: LiveChannel, lineup: [LiveChannel]? = nil) {
        _session = StateObject(wrappedValue: DirectPlaybackSession(channel: VelagramStore.shared.defaultSource(for: channel)))
        self.lineup = lineup
    }
    private var isLive: Bool { session.channel.contentKind == nil && store.liveChannels.contains { $0.id == session.channel.id || ChannelSources.key($0) == ChannelSources.key(session.channel) } }
    private var sourceDisplayName: String {
        guard let source = store.sources(for: session.channel).first(where: { $0.id == session.channel.id }) else {
            return session.channel.name
        }
        let base = ChannelSources.basicName(source.name)
        var label = source.name
        if let range = label.range(of: base, options: [.caseInsensitive, .diacriticInsensitive]) {
            label.removeSubrange(range)
        }
        label = label.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|:._()[]{}")))
        return label.isEmpty ? String(localized: "Main source") : label
    }
    private func switchChannel(_ direction: Int) {
        guard isLive, let next = store.adjacentChannel(to: session.channel, direction: direction, in: lineup) else { return }
        session.channel = store.defaultSource(for: next)
    }
    private func switchSource(_ direction: Int) {
        let sources = store.sources(for: session.channel)
        guard sources.count > 1, let index = sources.firstIndex(where: { $0.id == session.channel.id }) else { return }
        chooseSource(sources[(index + direction + sources.count) % sources.count])
    }
    private func chooseSource(_ source: LiveChannel) {
        var channel = source
        channel.name = ChannelSources.basicName(session.channel.name)
        session.channel = channel
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            GeometryReader { viewport in
                DirectPlayerController(player: session.player, onDismiss: { dismiss() }, onNext: isLive ? { switchChannel(1) } : nil, onPrevious: isLive ? { switchChannel(-1) } : nil, onSourceSwipe: { switchSource($0) }, onControlsVisibilityChange: { visible in
                withAnimation(.easeInOut(duration: 0.12)) { controlsVisible = visible }
            }).frame(width: viewport.size.width, height: viewport.size.height)
            }.ignoresSafeArea()
            if session.loading {
                ProgressView("Opening stream…").padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let failure = session.failure {
                VStack(spacing: 16) {
                    ContentUnavailableView("Playback unavailable", systemImage: "exclamationmark.tv", description: Text(failure))
                    Button("Close player") { dismiss() }.buttonStyle(.borderedProminent)
                }.padding().background(.black.opacity(0.9))
            }

            if isLive {
                HStack(alignment: .top, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sourceDisplayName).font(.headline).accessibilityIdentifier("live.sourceName")
                            Text(store.now(session.channel)?.title ?? "Program information unavailable").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .onChange(of: store.now(session.channel)?.id) { _, _ in session.updateMetadata() }
                            .onAppear { session.updateMetadata() }
                    }
                    Spacer(minLength: 0)
                    if store.sources(for: session.channel).count > 1 {
                        Menu {
                            ForEach(store.sources(for: session.channel)) { source in
                                Button { chooseSource(source) } label: {
                                    Label(source.name, systemImage: source.id == session.channel.id ? "checkmark.circle.fill" : "circle")
                                }
                            }
                        } label: {
                            Label("Change source", systemImage: "rectangle.2.swap").labelStyle(.iconOnly)
                                .padding(12).background(.ultraThinMaterial, in: Capsule())
                        }.accessibilityIdentifier("live.changeSource")
                            .accessibilityValue(store.sources(for: session.channel).first { $0.id == session.channel.id }?.name ?? session.channel.name)
                    }
                    Button { showGuide = true } label: { Label("EPG", systemImage: "list.bullet.rectangle").padding(12).background(.ultraThinMaterial, in: Capsule()) }
                        .accessibilityIdentifier("live.epg")
                }.padding(.horizontal).padding(.top, 72)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
            }
        }
        .task(id: session.channel.id) { await session.start() }
        .onDisappear { session.stop() }.preferredColorScheme(.dark)
        .sheet(isPresented: $showGuide) {
            NavigationStack {
                ChannelGuideView(channel: session.channel, lineup: lineup, watchLive: { channel in
                    session.channel = store.defaultSource(for: channel); showGuide = false
                }) { channel in
                    showGuide = false; replay = OnDemandLibraryView.playable(channel)
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGuide = false } } }
            }.presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $replay, onDismiss: { session.player.play() }) { stream in
            IPTVSourcePlayerView(stream: stream).onAppear { session.player.pause() }
        }
        .accessibilityAction(named: "Next channel") { switchChannel(1) }
        .accessibilityAction(named: "Previous channel") { switchChannel(-1) }
    }
}

private struct DirectPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDismiss: () -> Void
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSourceSwipe: ((Int) -> Void)?
    var onControlsVisibilityChange: ((Bool) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss, onNext: onNext, onPrevious: onPrevious) }
    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        let onDismiss: () -> Void
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        var onSourceSwipe: ((Int) -> Void)?
        init(onDismiss: @escaping () -> Void, onNext: (() -> Void)?, onPrevious: (() -> Void)?) {
            self.onDismiss = onDismiss; self.onNext = onNext; self.onPrevious = onPrevious
        }
        @objc func swipe(_ gesture: UISwipeGestureRecognizer) {
            switch gesture.direction {
            case .up: onNext?()
            case .down: onPrevious?()
            case .left: onSourceSwipe?(-1)
            case .right: onSourceSwipe?(1)
            default: break
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }
        func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.onDismiss() }
        }
    }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = DismissibleDirectController()
        controller.close = onDismiss
        controller.onControlsVisibilityChange = onControlsVisibilityChange
        controller.delegate = context.coordinator
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        if onNext != nil || onPrevious != nil {
            for direction: UISwipeGestureRecognizer.Direction in [.up, .down, .left, .right] {
                let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipe(_:)))
                swipe.direction = direction; swipe.delegate = context.coordinator
                swipe.cancelsTouchesInView = false
                controller.view.addGestureRecognizer(swipe)
            }
        }
        context.coordinator.onSourceSwipe = onSourceSwipe
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onSourceSwipe = onSourceSwipe
        context.coordinator.onNext = onNext; context.coordinator.onPrevious = onPrevious
        (controller as? DismissibleDirectController)?.onControlsVisibilityChange = onControlsVisibilityChange
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        (controller as? DismissibleDirectController)?.stopVisibilityTracking()
        controller.player = nil
    }
}

private final class DismissibleDirectController: PlayerControlsTrackingController {
    var close: (() -> Void)?
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        close?(); completion?()
    }
}

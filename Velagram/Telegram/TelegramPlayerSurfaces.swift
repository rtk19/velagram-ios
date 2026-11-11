import SwiftUI
import AVKit
import MediaPlayer
import VLCKit

struct TelegramNativePlayerController: UIViewControllerRepresentable {
    let session: TelegramPlayerSession
    let onDoubleTap: (CGFloat) -> Void
    let onHold: (Bool) -> Void
    let onTap: () -> Void
    func makeCoordinator() -> PlayerGestureCoordinator { PlayerGestureCoordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = session.nativePlayer
        controller.showsPlaybackControls = true; controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = false
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        context.coordinator.install(in: controller.view, singleTap: true)
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.videoGravity = session.fitToFill ? .resizeAspectFill : .resizeAspect
        context.coordinator.excludesTouch = { point, view in
            point.x >= view.bounds.width - view.safeAreaInsets.right - 72 && abs(point.y - view.bounds.midY) <= 32
        }
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap; context.coordinator.onHold = onHold
        context.coordinator.onZoom = { session.fitToFill = $0 }
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: PlayerGestureCoordinator) { coordinator.remove(); controller.player = nil }
}
struct PlayerAirPlayButton: UIViewRepresentable {
    var video = true
    let onPresent: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = .white; view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = video; view.delegate = context.coordinator; return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) { context.coordinator.onPresent = onPresent; view.prioritizesVideoDevices = video; view.accessibilityLabel = video ? "AirPlay video" : "AirPlay audio" }
    @MainActor final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresent: () -> Void = {}
        nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { Task { @MainActor [weak self] in self?.onPresent() } }
    }
}
struct PlayerVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 30))
        view.tintColor = .white
        return view
    }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

final class PiPClock: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (Double, Double, Bool) = (0, 0, false)
    func update(position: Double, duration: Double, playing: Bool) { lock.withLock { state = (position, duration, playing) } }
    func read() -> (Double, Double, Bool) { lock.withLock { state } }
}
@MainActor final class VLCPiPMediaController: NSObject, VLCPictureInPictureMediaControlling {
    weak var session: TelegramPlayerSession?
    nonisolated let clock = PiPClock()
    nonisolated func play() { Task { @MainActor [weak self] in self?.session?.play() } }
    nonisolated func pause() { Task { @MainActor [weak self] in self?.session?.pause() } }
    nonisolated func seek(by offset: Int64, completion: @escaping () -> Void) {
        let done = PiPSeekCompletion(completion)
        Task { @MainActor [weak self] in guard let session = self?.session else { done.finish(); return }; session.seek(session.position + Double(offset) / 1000); done.finish() }
    }
    nonisolated func mediaLength() -> Int64 { Int64(clock.read().1 * 1000) }
    nonisolated func mediaTime() -> Int64 { Int64(clock.read().0 * 1000) }
    nonisolated func isMediaSeekable() -> Bool { clock.read().1 > 0 }
    nonisolated func isMediaPlaying() -> Bool { clock.read().2 }
}
final class PiPWindowReference: @unchecked Sendable {
    let value: any VLCPictureInPictureWindowControlling
    init(_ value: any VLCPictureInPictureWindowControlling) { self.value = value }
}
@MainActor final class VLCVideoCanvas: UIView, VLCPictureInPictureDrawable {
    nonisolated let controller: VLCPiPMediaController
    override init(frame: CGRect) { controller = VLCPiPMediaController(); super.init(frame: frame) }
    required init?(coder: NSCoder) { controller = VLCPiPMediaController(); super.init(coder: coder) }
    nonisolated func mediaController() -> any VLCPictureInPictureMediaControlling { controller }
    nonisolated func pictureInPictureReady() -> (((any VLCPictureInPictureWindowControlling)?) -> Void)? {
        { [weak controller] pip in
            guard let pip else { return }; let reference = PiPWindowReference(pip)
            Task { @MainActor [weak controller] in controller?.session?.pipController = reference.value }
        }
    }
}
struct TelegramVideoSurface: UIViewRepresentable {
    let session: TelegramPlayerSession
    func makeUIView(context: Context) -> UIView {
        let view: UIView
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let canvas = VLCVideoCanvas(); canvas.controller.session = session; session.pipAdapter = canvas.controller; view = canvas
        } else { view = UIView() }
        view.backgroundColor = .black; session.player.drawable = view; return view
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        weak var player: VLCMediaPlayer?
        var fill: Bool?
    }
    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.player !== session.player || context.coordinator.fill != session.fitToFill else { return }
        context.coordinator.player = session.player; context.coordinator.fill = session.fitToFill
        if session.player.drawable as? UIView !== view { session.player.drawable = view }
        session.player.videoFitMode = session.fitToFill ? .larger : .smaller
    }
}

final class PiPSeekCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (() -> Void)?
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func finish() { let action = lock.withLock { let value = callback; callback = nil; return value }; action?() }
}
@MainActor final class VLCPlaybackEvents: NSObject, VLCMediaPlayerDelegate {
    weak var session: TelegramPlayerSession?
    nonisolated func mediaPlayerRateChanged(_ rate: Float) {
        let observed = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in self?.session?.rateDidChange(rate, at: observed) }
    }
    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) { Task { @MainActor [weak self] in self?.session?.buffering = progress < 1 } }
}

/// Vela's original skip control, shared across the native and VLC playback paths.
struct PlaybackEpisodeActionButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(title).font(.subheadline.weight(.semibold))
                Image(systemName: "forward.end.fill").font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 17)
            .frame(minHeight: 44)
            .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.72)) }
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1) }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

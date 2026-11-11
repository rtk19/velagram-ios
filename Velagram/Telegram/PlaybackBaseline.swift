#if DEBUG
import SwiftUI
import AVKit
import VLCKit

/// Controlled diagnostic: the upstream UIKit player, without the production
/// session, SwiftUI overlay, Telegram transport, resume, captions or speed code.
struct PlaybackBaseline: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PlaybackBaselineController { PlaybackBaselineController() }
    func updateUIViewController(_ controller: PlaybackBaselineController, context: Context) {}
}
@MainActor final class PlaybackBaselineController: UIViewController {
    private var vlc: VLCMediaPlayer?
    private var native: AVPlayerViewController?
    private var tick: Timer?
    private var diagnostics: PlaybackDiagnostics?
    private var stream: TelegramStreamServer?
    private var seeked = false
    private var targetPosition: Double = 0
    private let label = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        label.textColor = .white; label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), label.centerXAnchor.constraint(equalTo: view.centerXAnchor)])
        UIApplication.shared.isIdleTimerDisabled = true
        Task { await open() }
    }
    private func open() async {
        let environment = ProcessInfo.processInfo.environment
        let kind = environment["VELAGRAM_BASELINE_KIND"] ?? "vlc"
        let file = kind == "native" ? "baseline.mp4" : "baseline.mkv"
        var url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: file)
        diagnostics = PlaybackDiagnostics()
        diagnostics?.event("baseline_start", ["engine": kind.hasPrefix("vlc") ? 2 : 3, "local": 1])
        if kind == "vlc-stream" {
            let store = TelegramStore.shared
            await store.start()
            for _ in 0..<100 where !store.ready { try? await Task.sleep(for: .milliseconds(100)) }
            guard var media = store.recentMedia.first else { label.text = "No recent test source"; return }
            do {
                if let fresh = TelegramMedia.parse(try await store.transport.call("getMessage", ["chat_id": .integer(media.chatID), "message_id": .integer(media.messageID)])) { media = fresh }
                let server = try TelegramStreamServer(transport: store.transport, media: media, diagnostics: diagnostics)
                stream = server; url = try await server.start(filename: media.name)
                let saved = VelagramStore.shared.progress["telegram:\(media.id)"]?.position ?? 0
                targetPosition = saved / max(1, Double(media.duration))
                diagnostics?.event("baseline_stream")
            } catch { label.text = "Stream failed"; diagnostics?.event("baseline_error", ["code": Double((error as NSError).code)]); return }
        }
        label.text = "\(kind.uppercased()) · 1×"
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if kind.hasPrefix("vlc") {
            let canvas = UIView(); mount(canvas)
            let player = VLCMediaPlayer(); vlc = player; player.drawable = canvas
            player.media = VLCMedia(url: url); player.play()
        } else {
            let controller = AVPlayerViewController(); native = controller
            addChild(controller); mount(controller.view); controller.didMove(toParent: self)
            controller.player = AVPlayer(url: url); controller.player?.play()
        }
        view.bringSubviewToFront(label)
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }
    private func mount(_ surface: UIView) {
        surface.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(surface)
        NSLayoutConstraint.activate([surface.leadingAnchor.constraint(equalTo: view.leadingAnchor), surface.trailingAnchor.constraint(equalTo: view.trailingAnchor), surface.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40), surface.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)])
    }
    private func sample() {
        var values: [String: Double] = ["application_state": Double(UIApplication.shared.applicationState.rawValue)]
        if let player = vlc {
            if !seeked, player.isPlaying, targetPosition > 0, targetPosition < 1 { seeked = true; player.position = targetPosition }
            values["position"] = Double(player.time.intValue) / 1000; values["playing"] = player.isPlaying ? 1 : 0
            if let stats = player.media?.statistics { values["lost_frames"] = Double(stats.lostPictures); values["displayed_frames"] = Double(stats.displayedPictures); values["lost_audio"] = Double(stats.lostAudioBuffers) }
        } else if let player = native?.player {
            let time = player.currentTime().seconds
            if time.isFinite { values["position"] = time }; values["playing"] = player.rate > 0 ? 1 : 0
        }
        diagnostics?.event("baseline_sample", values)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); stream?.stop(); tick?.invalidate(); vlc?.stop(); native?.player?.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
#endif

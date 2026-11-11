import SwiftUI
import GoogleCastDynamic

struct CastPlaybackPayload {
    let url: URL
    let title: String
    let mimeType: String
    let position: Double
    let duration: Double
    var subtitleURL: URL? = nil
}

@MainActor final class GoogleCastPlayback: NSObject, GCKSessionManagerListener, GCKRequestDelegate {
    static let shared = GoogleCastPlayback()
    private static var configured = false
    var prepare: (() async throws -> CastPlaybackPayload)?
    var onStarted: (() -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private var cacheLease: CacheUsage.Lease?
    private var loading: GCKRequest?
    private var prepareTask: Task<Void, Never>?
    private var active = false
    private var retainedServer: TelegramStreamServer?
    private var retainedRelay: CastHTTPRelay?
    private var progressTask: Task<Void, Never>?
    var onProgress: ((Double, Double) -> Void)?
    func retain(_ server: TelegramStreamServer?) {
        if retainedServer !== server { retainedServer?.stop() }; retainedServer = server
        retainedRelay?.stop(); retainedRelay = nil
    }
    func retain(_ relay: CastHTTPRelay?) {
        if retainedRelay !== relay { retainedRelay?.stop() }; retainedRelay = relay
        retainedServer?.stop(); retainedServer = nil
    }
    var remoteProgress: (position: Double, duration: Double)? {
        guard active, let client else { return nil }
        return (client.approximateStreamPosition(), client.mediaStatus?.mediaInformation?.streamDuration ?? 0)
    }
    static func configure() {
        guard !configured else { return }; configured = true
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
        options.startDiscoveryAfterFirstTapOnCastButton = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(shared)
    }
    var client: GCKRemoteMediaClient? {
        guard Self.configured else { return nil }
        return GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }
    func castIfConnected() {
        guard let client, let prepare else { return }
        progressTask?.cancel(); progressTask = nil; active = false
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            do {
                if self?.cacheLease == nil { self?.cacheLease = try await CacheUsage.shared.waitForReader() }
                let payload = try await prepare()
                try Task.checkCancellation()
                let metadata = GCKMediaMetadata(metadataType: .movie)
                metadata.setString(payload.title, forKey: kGCKMetadataKeyTitle)
                let info = GCKMediaInformationBuilder(contentURL: payload.url)
                info.contentType = payload.mimeType; info.streamType = .buffered; info.streamDuration = payload.duration
                info.metadata = metadata
                if let url = payload.subtitleURL {
                    info.mediaTracks = [GCKMediaTrack(identifier: 1, contentIdentifier: url.absoluteString, contentType: "text/vtt", type: .text,
                        textSubtype: .subtitles, name: "Selected subtitles", languageCode: nil, customData: nil)].compactMap { $0 }
                }
                let request = GCKMediaLoadRequestDataBuilder()
                request.mediaInformation = info.build(); request.startTime = payload.position; request.autoplay = true
                if payload.subtitleURL != nil { request.activeTrackIDs = [1] }
                self?.loading = client.loadMedia(with: request.build()); self?.loading?.delegate = self
            } catch { if !Task.isCancelled { self?.onFailure?(error.localizedDescription) } }
        }
    }
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) { Task { @MainActor [weak self] in self?.castIfConnected() } }
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResume session: GCKCastSession) { Task { @MainActor [weak self] in self?.castIfConnected() } }
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }; self.active = false; self.progressTask?.cancel(); self.progressTask = nil
            self.retainedServer?.stop(); self.retainedServer = nil; self.retainedRelay?.stop(); self.retainedRelay = nil; self.onProgress = nil; self.cacheLease?.release(); self.cacheLease = nil; self.onEnded?()
        }
    }
    nonisolated func requestDidComplete(_ request: GCKRequest) {
        let id = request.requestID
        Task { @MainActor [weak self] in
            guard let self, self.loading?.requestID == id else { return }
            self.active = true; self.onStarted?(); self.loading = nil; self.progressTask?.cancel()
            self.progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.active, let client = self.client else { return }
                    self.onProgress?(client.approximateStreamPosition(), client.mediaStatus?.mediaInformation?.streamDuration ?? 0)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }
    nonisolated func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        Task { @MainActor [weak self] in
            self?.loading = nil
            self?.onFailure?("The Cast receiver could not open this release. Try an MP4/H.264 release supported by your TV. Local playback is still available.")
        }
    }
    func clear() {
        prepareTask?.cancel(); prepareTask = nil
        prepare = nil; onStarted = nil; onEnded = nil; onFailure = nil; loading?.cancel(); loading = nil
        if !active { cacheLease?.release(); cacheLease = nil; retainedServer?.stop(); retainedServer = nil; retainedRelay?.stop(); retainedRelay = nil; progressTask?.cancel(); progressTask = nil; onProgress = nil }
    }
}

struct GoogleCastRouteButton: UIViewRepresentable {
    var onTap: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> GCKUICastButton {
        GoogleCastPlayback.configure()
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        button.setImage(UIImage(systemName: "tv.badge.wifi"), for: .normal)
        button.tintColor = .white; button.accessibilityLabel = "Google Cast"
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: GCKUICastButton, context: Context) { context.coordinator.onTap = onTap }
    @MainActor final class Coordinator: NSObject {
        var onTap: () -> Void = {}
        @objc func tapped() { onTap(); GoogleCastPlayback.shared.castIfConnected() }
    }
}

struct WebCastRouteButton: View {
    let source: PlaybackSource
    let request: PlaybackRequest
    let library: LibraryStore
    var nextRequest: PlaybackRequest? = nil
    let position: () -> Double
    let duration: () -> Double
    let onStarted: () -> Void
    let onEnded: () -> Void
    @State private var notice: String?
    var body: some View {
        GoogleCastRouteButton().frame(width: 44, height: 44)
            .task(id: source.url) { configure() }
            .onDisappear { GoogleCastPlayback.shared.clear() }
            .alert("Google Cast", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK") { notice = nil } } message: { Text(notice ?? "") }
    }
    private func configure() {
        let manager = GoogleCastPlayback.shared
        manager.prepare = { [weak library] in
            let url: URL
            if source.headers.isEmpty { url = source.url; manager.retain(nil as CastHTTPRelay?) }
            else {
                let relay = try CastHTTPRelay(headers: source.headers)
                url = try await relay.start(origin: source.url); try Task.checkCancellation(); manager.retain(relay)
            }
            var completed = false
            manager.onProgress = { position, duration in
                guard !completed, duration > 0, duration.isFinite, position.isFinite else { return }
                if PlaybackCompletionPolicy.shouldFinishEpisodeOnExit(request: request, position: position, duration: duration) {
                    completed = true; library?.markFinished(request: request, nextRequest: nextRequest)
                } else { library?.updateProgress(request: request, position: position, duration: duration) }
            }
            let hls = source.url.absoluteString.lowercased().contains("m3u8")
            return CastPlaybackPayload(url: url, title: request.displayTitle, mimeType: hls ? "application/vnd.apple.mpegurl" : "video/mp4", position: position(), duration: duration())
        }
        manager.onStarted = onStarted; manager.onEnded = onEnded; manager.onFailure = { notice = $0 }
    }
}

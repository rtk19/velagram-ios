import SwiftUI
import AVKit
import MediaPlayer
import MediaAccessibility
import VLCKit
import GoogleCastDynamic
import UniformTypeIdentifiers

struct PlayerTrackChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let selected: Bool
}

@MainActor @Observable final class TelegramPlayerSession {
    var player = VLCMediaPlayer()
    let nativePlayer = AVPlayer()
    var canPictureInPicture: Bool { pipController != nil }
    func startPictureInPicture() { pipController?.startPictureInPicture() }
    let store: TelegramStore
    let catalogRequest: PlaybackRequest?
    let library: LibraryStore?
    var nextCatalogRequest: PlaybackRequest? {
        didSet {
            if catalogCompleted, let catalogRequest, let nextCatalogRequest {
                library?.markFinished(request: catalogRequest, nextRequest: nextCatalogRequest)
            }
        }
    }
    var skipSegments: [PlaybackSkipSegment] = []
    private var catalogCompleted = false
    var playbackEnded: Bool { ended }
    private let rememberPlayback: Bool
    var current: TelegramMedia
    var queue: [TelegramMedia]
    var failure: String?
    var notice: String?
    var opening = true
    var playing = false
    var buffering = false
    var videoDimensions: CGSize = .zero
    private var lastDetailsRefresh: TimeInterval = 0
    var transfer = PlaybackTransferSnapshot()
    var diagnostics: PlaybackDiagnostics?
    var diagnosticsURL: URL? { diagnostics?.url }
    private var metricsTask: Task<Void, Never>?
    private var subtitleDiscoveryTask: Task<Void, Never>?
    private var cacheLease: CacheUsage.Lease?
    private var lastAdvance = ProcessInfo.processInfo.systemUptime
    private(set) var userPaused = false
    var useNative = false
    var casting = false
    var pipController: (any VLCPictureInPictureWindowControlling)?
    weak var pipAdapter: VLCPiPMediaController?
    var hasExternalSubtitles: Bool { !externalCues.isEmpty }
    private var externalRenderedByVLC = false
    var position: Double = 0
    var duration: Double = 0
    var rate: Float = 1
    var temporaryRate = false
    private(set) var appliedRate: Float = 1
    private var pendingRateChange: (rate: Float, time: TimeInterval)?
    var audioDelay: Double = 0
    var subtitleDelay: Double = 0
    var subtitleText = ""
    var subtitleName = "Automatic"
    var audioTracks: [PlayerTrackChoice] = []
    var textTracks: [PlayerTrackChoice] = []
    var sleepDeadline: Date?
    var fitToFill = false {
        didSet { if rememberPlayback, let catalogRequest { library?.updatePlayerZoomedToFill(fitToFill, for: catalogRequest) } }
    }
    private var nativeAudioGroup: AVMediaSelectionGroup?
    private var nativeTextGroup: AVMediaSelectionGroup?
    private var nativeTracksLoaded = false
    private let embeddedCaptions = MatroskaCaptionCache()
    private var embeddedTextID: String?
    private var embeddedTrackIndex: Int?
    private(set) var externalCues: [SubtitleCue] = []
    private(set) var externalSubtitleSource: SubtitleSource?
    private var selectedSubtitleID = "auto"
    private var playbackURL: URL?
    private var originalURL: URL?
    private var airPlayAttempted = false
    private var server: TelegramStreamServer?
    private var networkServer: TelegramStreamServer?
    private var networkURL: URL?
    private var resumed = false
    private var ended = false
    private var stopped = false
    private var nativeFallbackAttempted = false
    private var vlcEvents: VLCPlaybackEvents?
    private var pendingResume: Double?
    private var lastPersistedSecond = -1
    private var interruptionWasPlaying = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var previousIdleDisabled = false
    var progressID: String { current.remoteURL.map { "remote:" + LiveChannel.identity($0.absoluteString) } ?? "telegram:\(current.id)" }
    private var rateKey: String { current.episode == nil ? progressID : "series:\(current.seriesKey)" }
    var next: TelegramMedia? {
        guard let index = queue.firstIndex(where: { $0.id == current.id }), index + 1 < queue.count else { return nil }
        return queue[index + 1]
    }
    init(media: TelegramMedia, store: TelegramStore, queue: [TelegramMedia], catalogRequest: PlaybackRequest? = nil, library: LibraryStore? = nil, rememberPlayback: Bool = true) {
        self.rememberPlayback = rememberPlayback
        current = media; self.store = store; self.queue = queue; self.catalogRequest = catalogRequest; self.library = library
    }
    var sourceHeaders: [String: String] = [:]
    private var captionAppearance = SystemCaptionStyle.current()
    func refreshCaptionAppearance() {
        let style = SystemCaptionStyle.current()
        guard style != captionAppearance else { return }
        captionAppearance = style
        // Caption appearance changes do not restart or reconfigure the decoder.
        // Parsed captions read the device style directly in the overlay.
    }
    nonisolated static func prefersNative(_ media: TelegramMedia) -> Bool {
        ["mp4", "m4v", "mov", "m3u8", "mp3", "m4a", "aac"].contains((media.name as NSString).pathExtension.lowercased())
            || media.mimeType == "application/vnd.apple.mpegurl"
    }
    func start(environment: AppEnvironment? = nil) async {
        subtitleDiscoveryTask?.cancel()
        metricsTask?.cancel()
        embeddedTextID = nil; embeddedTrackIndex = nil
        diagnostics = PlaybackDiagnostics(total: current.size)
        diagnostics?.event("start", ["native_preferred": Self.prefersNative(current) ? 1 : 0, "total": Double(current.size)])
        transfer = .init(); lastAdvance = ProcessInfo.processInfo.systemUptime; userPaused = false
        stopped = false; failure = nil; opening = true; resumed = false; ended = false; position = 0; appliedRate = 1; pendingRateChange = nil
        externalCues = []; externalSubtitleSource = nil; externalRenderedByVLC = false; selectedSubtitleID = "auto"; subtitleName = "Automatic"
        textTracks = []; audioTracks = []; nativeFallbackAttempted = false
        let timing = UserDefaults.standard.dictionary(forKey: "velagram.telegram.timing.\(progressID)") as? [String: Double] ?? [:]
        audioDelay = timing["audio"] ?? 0; subtitleDelay = timing["subtitle"] ?? 0
        if let catalogRequest { fitToFill = library?.isPlayerZoomedToFill(for: catalogRequest) ?? false }
        duration = max(Double(current.duration), VelagramStore.shared.progress[progressID]?.duration ?? 0)
        do {
            if cacheLease == nil { cacheLease = try await CacheUsage.shared.waitForReader() }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let orientation = PlayerOrientationPreference(rawValue: UserDefaults.standard.string(forKey: "player.orientation") ?? "") ?? .autoRotate
            AppOrientationController.shared.beginPlayback(using: orientation)
            if notificationTokens.isEmpty { previousIdleDisabled = UIApplication.shared.isIdleTimerDisabled; installSystemControls() }
            UIApplication.shared.isIdleTimerDisabled = true
            let url: URL
            if let local = TelegramDownloads.shared.local(current) { url = local }
            else if let remote = current.remoteURL { url = remote }
            else {
                if let fresh = TelegramMedia.parse(try await store.transport.call("getMessage", ["chat_id": .integer(current.chatID), "message_id": .integer(current.messageID)])) { current = fresh }
                let stream = try TelegramStreamServer(transport: store.transport, media: current, diagnostics: diagnostics) { [weak self] message in
                    Task { @MainActor [weak self] in guard let self, !self.stopped else { return }; self.failure = message; self.opening = false }
                }
                server = stream; url = try await stream.start(filename: current.name)
            }
            try Task.checkCancellation(); guard !stopped else { return }
            playbackURL = url; originalURL = url
            let remembered = UserDefaults.standard.dictionary(forKey: "velagram.telegram.playbackRates") as? [String: Double] ?? [:]
            let defaultRate = UserDefaults.standard.object(forKey: "player.defaultPlaybackRate") as? Double ?? 1
            rate = Float(catalogRequest.flatMap { library?.playbackRate(for: $0, defaultRate: defaultRate) } ?? remembered[rateKey] ?? defaultRate)
            if rememberPlayback, current.chatID != 0 { store.remember(current) }
            useNative = Self.prefersNative(current)
            if let environment, catalogRequest != nil, subtitlesEnabled {
                if UserDefaults.standard.string(forKey: "player.subtitleLoadingMode") == SubtitleLoadingMode.completeBeforePlayback.rawValue {
                    await loadPreferredSubtitles(environment: environment)
                    try Task.checkCancellation(); guard !stopped else { return }
                } else {
                    subtitleDiscoveryTask = Task { [weak self] in guard let self else { return }; await self.loadPreferredSubtitles(environment: environment) }
                }
            }
            if useNative { openNative(url) } else { try openVLC(url) }
            startMetrics()
            configureCasting()
            while !Task.isCancelled && !stopped {
                await update()
                if let deadline = sleepDeadline, Date() >= deadline { pause(); sleepDeadline = nil; notice = "Sleep timer finished" }
                if failure != nil { pause(); break }
                if ended, catalogRequest == nil, let next, UserDefaults.standard.object(forKey: "player.autoNext") as? Bool ?? true {
                    persist(); player.stop(); nativePlayer.pause(); server?.stop(); server = nil; current = next
                    await start(); return
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        } catch { if !Task.isCancelled && !stopped { diagnostics?.event("start_error", ["code": Double((error as NSError).code)]); opening = false; failure = error.localizedDescription } }
    }
    private func startMetrics() {
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                if self.current.remoteURL == nil, let id = self.current.fileID {
                    if let json = try? await self.store.transport.call("getFile", ["file_id": .integer(Int64(id))], timeout: 3), let file = TelegramFile(json) {
                        self.diagnostics?.sample(file)
                        await self.refreshEmbeddedCaptions(file: file)
                    }
                }
                self.transfer = self.diagnostics?.snapshot() ?? .init()
                var values: [String: Double] = ["position": self.position, "duration": self.duration, "opening": self.opening ? 1 : 0, "buffering": self.buffering ? 1 : 0, "playing": self.playing ? 1 : 0, "native": self.useNative ? 1 : 0, "system_volume": Double(AVAudioSession.sharedInstance().outputVolume), "audio_delay_seconds": self.audioDelay, "requested_rate": Double(self.useNative ? self.nativePlayer.rate : self.player.rate), "applied_rate": Double(self.useNative ? self.nativePlayer.rate : self.appliedRate), "temporary_rate": self.temporaryRate ? 1 : 0, "application_state": Double(UIApplication.shared.applicationState.rawValue), "subtitle_delay_seconds": self.subtitleDelay,
                    "downloaded": Double(self.transfer.downloaded), "total": Double(self.transfer.total), "bytes_per_second": self.transfer.bytesPerSecond, "served_bytes": Double(self.transfer.delivered), "waiting_reads": Double(self.transfer.waitingReads), "download_active": self.transfer.downloading ? 1 : 0, "prefix_offset": Double(self.transfer.prefixOffset), "prefix_bytes": Double(self.transfer.prefixBytes)]
                if !self.useNative, let media = self.player.media {
                    let stats = media.statistics
                    values["vlc_state"] = Double(self.player.state.rawValue)
                    values["input_bytes"] = Double(stats.readBytes); values["demux_bytes"] = Double(stats.demuxReadBytes)
                    values["decoded_video"] = Double(stats.decodedVideo); values["decoded_audio"] = Double(stats.decodedAudio)
                    values["displayed_frames"] = Double(stats.displayedPictures); values["lost_frames"] = Double(stats.lostPictures)
                    values["played_audio"] = Double(stats.playedAudioBuffers); values["lost_audio"] = Double(stats.lostAudioBuffers)
                }
                self.diagnostics?.event("sample", values)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func refreshEmbeddedCaptions(file: TelegramFile) async {
        guard !useNative, (current.name as NSString).pathExtension.lowercased() == "mkv",
              selectedSubtitleID != "off", selectedSubtitleID != "external",
              let path = TelegramFileReader.readablePath(file.localPath) else { return }
        if externalCues.isEmpty, let index = player.textTracks.firstIndex(where: { $0.isSelected }) {
            embeddedTrackIndex = index; embeddedTextID = player.textTracks[index].trackId
        }
        guard let index = embeddedTrackIndex, let id = embeddedTextID else { return }
        let position = self.position
        if let cues = try? await embeddedCaptions.captions(path: path, offset: file.completed ? 0 : file.downloadOffset,
            prefix: file.completed ? file.size : file.downloadedPrefixSize, position: position, trackIndex: index),
           embeddedTextID == id, !cues.isEmpty,
           !externalCues.isEmpty || cues.contains(where: { $0.endTime >= position && $0.startTime <= position + 3 }) {
            if externalCues != cues { externalCues = cues }
            if player.textTracks.contains(where: { $0.isSelected }) {
                subtitleName = player.textTracks.first(where: { $0.trackId == id })?.trackName ?? subtitleName
                player.deselectAllTextTracks()
                diagnostics?.event("embedded_captions_device_styled", ["cues": Double(cues.count)])
            }
        }
    }
    private func openNative(_ url: URL, autoplay: Bool = true) {
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": sourceHeaders])); item.preferredForwardBufferDuration = 5
        nativePlayer.allowsExternalPlayback = true; nativePlayer.appliesMediaSelectionCriteriaAutomatically = true
        nativePlayer.replaceCurrentItem(with: item); nativeTracksLoaded = false
        if autoplay { nativePlayer.playImmediately(atRate: rate) } else { nativePlayer.pause() }
    }
    private func openVLC(_ url: URL) throws {
        guard let media = VLCMedia(url: url) else { throw AppError.noStream }
        // Keep VLC's hardware decoder, renderer and A/V clock selection. MKV
        // VOD needs headroom for bursty HTTP/TDLib reads; the generic network
        // default is only one second. Local files do not need this latency.
        if !url.isFileURL, (current.name as NSString).pathExtension.lowercased() == "mkv" {
            media.addOption(":network-caching=3000")
        }
        if let referer = sourceHeaders["Referer"] { media.addOption(":http-referrer=" + referer) }
        if let agent = sourceHeaders["User-Agent"] { media.addOption(":http-user-agent=" + agent) }
        let events = VLCPlaybackEvents(); events.session = self; vlcEvents = events; player.delegate = events
        player.media = media; player.play()
    }
    private func update() async {
        let previous = position
        if casting, let client = GoogleCastPlayback.shared.client {
            position = max(0, client.approximateStreamPosition())
            playing = client.mediaStatus?.playerState == .playing
            buffering = client.mediaStatus?.playerState == .buffering
        } else if useNative {
            if nativePlayer.isExternalPlaybackActive, !airPlayAttempted, current.remoteURL == nil { await prepareAirPlay(); return }
            if nativePlayer.currentItem?.status == .failed, !nativeFallbackAttempted, let url = playbackURL {
                pendingResume = max(position, library.flatMap { library in catalogRequest.map { library.resumePosition(for: $0) } } ?? 0)
                nativeFallbackAttempted = true; nativePlayer.pause(); useNative = false; resumed = false
                do { try openVLC(url) } catch { failure = error.localizedDescription }; return
            }
            let value = nativePlayer.currentTime().seconds
            if value.isFinite { position = max(0, value) }
            let length = nativePlayer.currentItem?.duration.seconds ?? 0
            if length.isFinite { duration = max(duration, length) }
            playing = nativePlayer.rate > 0; buffering = nativePlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if nativePlayer.currentItem?.status == .readyToPlay {
                if !nativeTracksLoaded { await loadNativeTracks() } else { refreshNativeTracks() }
                if !resumed { await restorePosition() }
                opening = false
            }
            ended = resumed && duration > 0 && position >= duration - 0.3 && nativePlayer.rate == 0
        } else {
            playing = player.isPlaying
            position = max(0, Double(player.time.intValue) / 1000)
            let now = ProcessInfo.processInfo.systemUptime
            let refreshDetails = now - lastDetailsRefresh >= 1 || (player.isPlaying && audioTracks.isEmpty)
            if refreshDetails {
                lastDetailsRefresh = now
                duration = max(duration, Double(player.media?.length.intValue ?? 0) / 1000)
                let dimensions = player.videoSize
                if dimensions.width > 0, dimensions.height > 0, videoDimensions != dimensions { videoDimensions = dimensions }
                pipController?.invalidatePlaybackState()
            }
            if position > previous + 0.02 { lastAdvance = ProcessInfo.processInfo.systemUptime }
            if player.state == .opening { buffering = true }
            if player.state == .playing {
                buffering = !userPaused && ProcessInfo.processInfo.systemUptime - lastAdvance > 3
            }
            if player.state == .paused || player.state == .stopped { buffering = false }
            if player.state == .error { opening = false; failure = "This release could not be decoded. Choose another source or download it and retry." }
            if player.state == .playing, !resumed {
                resumed = true; opening = false; requestVLCRate(rate)
                if !externalCues.isEmpty { player.deselectAllTextTracks() }
                if catalogRequest != nil {
                    let language = UserDefaults.standard.string(forKey: "player.audioLanguage") ?? "en"
                    if let index = player.audioTracks.firstIndex(where: { SubtitleLanguage.canonicalCode($0.language) == SubtitleLanguage.canonicalCode(language) }) { player.selectTrack(at: index, type: .audio) }
                }
                let saved = pendingResume ?? catalogRequest.flatMap { library?.resumePosition(for: $0) } ?? VelagramStore.shared.progress[progressID]?.position ?? 0
                pendingResume = nil
                if saved > 0, saved < duration - 2 { seek(saved); position = saved }
                applyTiming()
            }
            if refreshDetails {
                let audio = player.audioTracks.map { PlayerTrackChoice(id: $0.trackId, name: $0.trackName, selected: $0.isSelected) }
                let text = player.textTracks.map { PlayerTrackChoice(id: $0.trackId, name: $0.trackName, selected: $0.trackId == embeddedTextID || ($0.isSelected && externalCues.isEmpty)) }
                if audioTracks != audio { audioTracks = audio }
                if textTracks != text { textTracks = text }
            }
            if selectedSubtitleID == "auto", !player.textTracks.isEmpty, catalogRequest != nil {
                if subtitlesEnabled {
                    let language = UserDefaults.standard.string(forKey: "player.subtitleLanguage.primary") ?? "en"
                    if let track = player.textTracks.first(where: { ($0.language ?? "").hasPrefix(language) }) { selectSubtitle(track.trackId) }
                } else { selectSubtitle(nil) }
            }
            if selectedSubtitleID == "auto", !player.textTracks.isEmpty,
               MACaptionAppearanceGetDisplayType(.user) == .alwaysOn {
                let languages = (MACaptionAppearanceCopySelectedLanguages(.user).takeRetainedValue() as? [String]) ?? Locale.preferredLanguages
                if let track = player.textTracks.first(where: { track in languages.contains { (track.language ?? "").hasPrefix(String($0.prefix(2))) } }) {
                    player.selectTextTracks([track]); selectedSubtitleID = track.trackId; subtitleName = track.trackName
                }
            }
            if resumed, player.state == .stopped, duration > 0, max(previous, position) >= duration - 2 { ended = true; position = duration }
        }
        subtitleText = useNative || !externalRenderedByVLC ? CaptionTimeline.text(at: position - subtitleDelay, cues: externalCues) : ""
        pipAdapter?.clock.update(position: position, duration: duration, playing: playing)
        if Int(position) != lastPersistedSecond { lastPersistedSecond = Int(position); persist(); updateNowPlaying() }
    }
    private func restorePosition() async {
        resumed = true
        let saved = pendingResume ?? catalogRequest.flatMap { library?.resumePosition(for: $0) } ?? VelagramStore.shared.progress[progressID]?.position ?? 0
        pendingResume = nil
        if saved > 0, saved < duration - 2 {
            await nativePlayer.seek(to: CMTime(seconds: saved, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            position = saved; lastPersistedSecond = Int(saved)
        }
    }
    private func loadNativeTracks() async {
        guard let item = nativePlayer.currentItem else { return }; nativeTracksLoaded = true
        nativeAudioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        nativeTextGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        if catalogRequest != nil, let group = nativeAudioGroup {
            let language = UserDefaults.standard.string(forKey: "player.audioLanguage") ?? "en"
            if let option = group.options.first(where: { SubtitleLanguage.canonicalCode($0.extendedLanguageTag ?? $0.locale?.language.languageCode?.identifier) == SubtitleLanguage.canonicalCode(language) }) { item.select(option, in: group) }
        }
        if !externalCues.isEmpty, let group = nativeTextGroup { item.select(nil, in: group) }
        else if catalogRequest != nil, let group = nativeTextGroup {
            let language = UserDefaults.standard.string(forKey: "player.subtitleLanguage.primary") ?? "en"
            if !subtitlesEnabled { item.select(nil, in: group); selectedSubtitleID = "off"; subtitleName = "Off" }
            else if let option = group.options.first(where: { ($0.extendedLanguageTag ?? $0.locale?.language.languageCode?.identifier ?? "").hasPrefix(language) }) {
                item.select(option, in: group); selectedSubtitleID = "preferred"; subtitleName = option.displayName
            }
        }
        refreshNativeTracks()
    }
    private func loadPreferredSubtitles(environment: AppEnvironment) async {
        guard let original = catalogRequest, subtitlesEnabled else { return }
        let request = await environment.canonicalPlaybackRequest(for: original)
        let settings = [("subdl", "subdl"), ("wizdom", "wizdom"), ("ktuvit", "ktuvit"), ("external-stream-subtitles", "externalStreams")]
        let enabled = Set(settings.filter { UserDefaults.standard.object(forKey: "subtitle.provider.\($0.1).enabled") as? Bool ?? true }.map(\.0))
        let lookup = request.subtitleLookupRequest ?? SubtitleLookupRequest(kind: request.media.kind, imdbID: "", seasonNumber: request.episode?.seasonNumber, episodeNumber: request.episode?.number, title: request.media.title)
        let sources = await environment.subtitleRegistry.subtitles(for: lookup, fallbackTMDbID: request.media.tmdbID, enabledProviderIDs: enabled)
        guard !Task.isCancelled, !stopped, selectedSubtitleID == "auto" || selectedSubtitleID == "preferred" else { return }
        let saved = library?.subtitleSelectionPreference(for: original)
        let primary = UserDefaults.standard.string(forKey: "player.subtitleLanguage.primary") ?? "en"
        let secondary = UserDefaults.standard.string(forKey: "player.subtitleLanguage.secondary") ?? ""
        let preferred = sources.first(where: { source in saved.map { source.matchesSyncKey($0.baseSubtitleKey) } ?? false })
            ?? SubtitleSource.firstAlphabetically(matching: primary, in: sources)
            ?? SubtitleSource.firstAlphabetically(matching: secondary, in: sources)
        guard let source = preferred else { return }
        do {
            var resource = URLRequest(url: source.url)
            source.headers.forEach { resource.setValue($0.value, forHTTPHeaderField: $0.key) }
            let response = try await SubtitleResourceRetry.load(request: resource, client: HTTPClient())
            let cues = try SubtitleParser.cues(from: response.data, languageCode: source.languageCode)
            guard !Task.isCancelled, !stopped, selectedSubtitleID == "auto" || selectedSubtitleID == "preferred" else { return }
            setExternalSubtitles(SubtitleDirectionFormatter.normalizedCues(cues, languageCode: source.languageCode), name: source.label, source: source)
        } catch { /* Subtitle availability must not prevent video playback. */ }
    }
    private var subtitlesEnabled: Bool {
        if let catalogRequest, let saved = library?.subtitleVisibilityPreference(for: catalogRequest) { return saved }
        return UserDefaults.standard.object(forKey: "player.subtitlesEnabledByDefault") as? Bool ?? true
    }
    private func refreshNativeTracks() {
        guard let item = nativePlayer.currentItem else { return }
        audioTracks = nativeAudioGroup.map { group in group.options.enumerated().map { index, option in
            PlayerTrackChoice(id: String(index), name: option.displayName, selected: item.currentMediaSelection.selectedMediaOption(in: group) == option)
        } } ?? []
        textTracks = nativeTextGroup.map { group in group.options.enumerated().map { index, option in
            PlayerTrackChoice(id: String(index), name: option.displayName, selected: externalCues.isEmpty && item.currentMediaSelection.selectedMediaOption(in: group) == option)
        } } ?? []
    }
    func selectAudio(_ id: String) {
        if useNative, let group = nativeAudioGroup, let index = Int(id), group.options.indices.contains(index) { nativePlayer.currentItem?.select(group.options[index], in: group); refreshNativeTracks() }
        else if let index = player.audioTracks.firstIndex(where: { $0.trackId == id }) { player.selectTrack(at: index, type: .audio) }
    }
    func selectSubtitle(_ id: String?) {
        if rememberPlayback, let catalogRequest { library?.updateSubtitleVisibilityPreference(id != nil, for: catalogRequest) }
        embeddedTextID = nil; embeddedTrackIndex = nil
        externalCues = []; externalSubtitleSource = nil; subtitleText = ""; selectedSubtitleID = id ?? "off"
        if useNative, let group = nativeTextGroup {
            let option = id.flatMap(Int.init).flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
            nativePlayer.currentItem?.select(option, in: group); subtitleName = option?.displayName ?? "Off"; refreshNativeTracks()
        } else {
            if let id, let track = player.textTracks.first(where: { $0.trackId == id }) { player.selectTextTracks([track]); subtitleName = track.trackName }
            else { player.deselectAllTextTracks(); subtitleName = "Off" }
        }
    }
    func setExternalSubtitles(_ cues: [SubtitleCue], name: String, source: SubtitleSource? = nil) {
        selectSubtitle(nil); externalCues = cues; selectedSubtitleID = "external"; subtitleName = name
        externalSubtitleSource = source
        if rememberPlayback, let source, let catalogRequest {
            let previous = library?.subtitleSelectionPreference(for: catalogRequest)
            library?.updateSubtitleSelectionPreference(SubtitleSelectionPreference(baseSubtitleKey: source.syncKey,
                syncVersionID: previous.flatMap { source.matchesSyncKey($0.baseSubtitleKey) ? $0.syncVersionID : nil }), for: catalogRequest)
        }
        if let source, let catalogRequest, let preference = library?.subtitleSelectionPreference(for: catalogRequest),
           source.matchesSyncKey(preference.baseSubtitleKey), let versionID = preference.syncVersionID,
           let version = library?.subtitleSyncVersions(for: catalogRequest).first(where: { $0.id == versionID }) {
            subtitleDelay = version.offset; applyTiming()
        }
        if rememberPlayback, let catalogRequest { library?.updateSubtitleVisibilityPreference(true, for: catalogRequest) }
        externalRenderedByVLC = false
        // Parsed text uses the same device-styled overlay for both engines.
        // VLC's CoreText renderer can retain embedded placement/style instead.

    }
    func importSubtitle(_ source: URL) throws {
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        do { setExternalSubtitles(try SubtitleParser.cues(from: data), name: source.lastPathComponent) }
        catch {
            guard !useNative else { throw error }
            let target = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + source.pathExtension)
            try data.write(to: target)
            guard player.addPlaybackSlave(target, type: .subtitle, enforce: true) == 0 else { throw error }
            subtitleName = source.lastPathComponent
        }
    }
    func pause() {
        userPaused = true; diagnostics?.event("pause")
        endTemporarySpeed()
        if casting { GoogleCastPlayback.shared.client?.pause() }
        else if useNative { nativePlayer.pause() } else { player.pause() }
        playing = false; updateNowPlaying()
    }
    func play() {
        userPaused = false; lastAdvance = ProcessInfo.processInfo.systemUptime; diagnostics?.event("play")
        if casting { GoogleCastPlayback.shared.client?.play() }
        else if useNative { nativePlayer.playImmediately(atRate: rate) } else { player.play(); requestVLCRate(rate) }
        playing = true; updateNowPlaying()
    }
    func toggle() { playing ? pause() : play() }
    func seek(_ seconds: Double) {
        guard duration > 0, seconds.isFinite else { return }
        let target = min(duration, max(0, seconds)); position = target
        lastAdvance = ProcessInfo.processInfo.systemUptime; diagnostics?.event("seek", ["target_seconds": target])
        if casting { let options = GCKMediaSeekOptions(); options.interval = target; GoogleCastPlayback.shared.client?.seek(with: options) }
        else if useNative { nativePlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        else { player.position = target / duration }
        updateNowPlaying()
    }
    func setRate(_ value: Float) {
        endTemporarySpeed(); rate = value
        if rememberPlayback, let catalogRequest { library?.updatePlaybackRate(Double(value), for: catalogRequest) }
        if casting { GoogleCastPlayback.shared.client?.setPlaybackRate(value) }
        else if useNative { if playing { nativePlayer.rate = value } } else { requestVLCRate(value) }
        var values = UserDefaults.standard.dictionary(forKey: "velagram.telegram.playbackRates") as? [String: Double] ?? [:]
        values[rateKey] = Double(value); if rememberPlayback { UserDefaults.standard.set(values, forKey: "velagram.telegram.playbackRates") }
    }
    func beginTemporarySpeed() {
        guard playing, !temporaryRate, !casting else { return }; temporaryRate = true
        diagnostics?.event("temporary_rate_start")
        if useNative { nativePlayer.rate = 2 } else { requestVLCRate(2) }
    }
    func endTemporarySpeed() {
        guard temporaryRate else { return }; temporaryRate = false
        diagnostics?.event("temporary_rate_end", ["rate": Double(rate)])
        if useNative { if playing { nativePlayer.rate = rate } }
        else {
            requestVLCRate(rate)
        }
    }
    private func requestVLCRate(_ value: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        pendingRateChange = (value, now)
        diagnostics?.event("rate_requested", ["rate": Double(value)])
        player.rate = value
    }
    func rateDidChange(_ value: Float, at observedTime: TimeInterval) {
        appliedRate = value
        var metrics: [String: Double] = ["rate": Double(value)]
        if let pending = pendingRateChange, abs(pending.rate - value) < 0.01 {
            metrics["latency_seconds"] = max(0, observedTime - pending.time)
            pendingRateChange = nil
        }
        diagnostics?.event("rate_applied", metrics)
    }
    func applyTiming() {
        player.currentAudioPlaybackDelay = Int(audioDelay * 1_000_000)
        player.currentVideoSubTitleDelay = Int(subtitleDelay * 1_000_000)
        if rememberPlayback { UserDefaults.standard.set(["audio": audioDelay, "subtitle": subtitleDelay], forKey: "velagram.telegram.timing.\(progressID)") }
    }
    func persist() {
        guard rememberPlayback, resumed, duration > 0, position.isFinite else { return }
        VelagramStore.shared.saveProgress(progressID, position: position, duration: duration)
        recordCatalogProgress(position: position, duration: duration)
    }
    func recordCatalogProgress(position: Double, duration: Double) {
        guard rememberPlayback, duration > 0, duration.isFinite, position.isFinite else { return }
        if let catalogRequest, !catalogCompleted {
            if PlaybackCompletionPolicy.shouldFinishEpisodeOnExit(request: catalogRequest, position: position, duration: duration, knownEndCreditsStart: skipSegments.first(where: { $0.kind == .outro })?.start) {
                finishCatalogPlayback()
            } else { library?.updateProgress(request: catalogRequest, position: position, duration: duration) }
        }
    }
    func finishCatalogPlayback() {
        guard rememberPlayback, let catalogRequest, !catalogCompleted else { return }
        catalogCompleted = true
        library?.markFinished(request: catalogRequest, nextRequest: nextCatalogRequest)
    }
    func prepareForNextCatalogEpisode() -> PlaybackRequest? {
        guard let nextCatalogRequest else { return nil }
        finishCatalogPlayback()
        if casting { GoogleCastPlayback.shared.client?.stop(); casting = false }
        stop()
        nativePlayer.replaceCurrentItem(with: nil)
        player.media = nil
        return nextCatalogRequest
    }
    func playQueueNext() async {
        guard catalogRequest == nil, let next else { return }
        persist(); player.stop(); nativePlayer.pause(); server?.stop(); server = nil; current = next
        await start()
    }
    func prepareNetworkURL() async throws -> URL {
        if let remote = current.remoteURL, !remote.isFileURL { return remote }
        if let networkURL { return networkURL }
        let stream = try TelegramStreamServer(transport: store.transport, media: current, networkSharing: true, localFile: TelegramDownloads.shared.local(current))
        let url = try await stream.start(filename: current.name); networkServer = stream; networkURL = url
        return url
    }
    func prepareAirPlay() async {
        airPlayAttempted = true
        guard useNative else { return }
        do {
            let url = try await prepareNetworkURL()
            guard url != playbackURL else { return }
            pendingResume = position; resumed = false; playbackURL = url; openNative(url, autoplay: playing && !casting)
        } catch { notice = error.localizedDescription }
    }
    private func configureCasting() {
        let cast = GoogleCastPlayback.shared
        cast.prepare = { [weak self] in
            guard let self else { throw AppError.noStream }
            let url = try await self.prepareNetworkURL()
            try Task.checkCancellation()
            GoogleCastPlayback.shared.retain(self.networkServer)
            let progressID = self.progressID; let request = self.catalogRequest; let library = self.library
            let nextRequest = self.nextCatalogRequest
            let credits = self.skipSegments.first(where: { $0.kind == .outro })?.start
            var completed = self.catalogCompleted
            let remember = self.rememberPlayback
            GoogleCastPlayback.shared.onProgress = { [weak library] position, duration in
                guard remember, duration > 0, duration.isFinite, position.isFinite else { return }
                VelagramStore.shared.saveProgress(progressID, position: position, duration: duration)
                if let request, !completed {
                    if PlaybackCompletionPolicy.shouldFinishEpisodeOnExit(request: request, position: position, duration: duration, knownEndCreditsStart: credits) {
                        completed = true; library?.markFinished(request: request, nextRequest: nextRequest)
                    } else { library?.updateProgress(request: request, position: position, duration: duration) }
                }
            }
            var payload = CastPlaybackPayload(url: url, title: self.catalogRequest?.displayTitle ?? self.current.title,
                mimeType: self.current.mimeType.isEmpty ? "video/mp4" : self.current.mimeType, position: self.position, duration: self.duration)
            if !self.externalCues.isEmpty { payload.subtitleURL = self.networkServer?.addResource(name: "subtitles.vtt", data: CaptionTimeline.webVTT(self.externalCues, delay: self.subtitleDelay), mimeType: "text/vtt") }
            return payload
        }
        cast.onStarted = { [weak self] in guard let self else { return }; self.endTemporarySpeed(); self.nativePlayer.pause(); self.player.pause(); self.casting = true; self.opening = false }
        cast.onEnded = { [weak self] in
            guard let self, self.casting else { return }; self.casting = false
            self.networkServer = nil; self.networkURL = nil; self.airPlayAttempted = false
            if self.useNative, let original = self.originalURL, self.playbackURL != original {
                self.pendingResume = self.position; self.resumed = false; self.playbackURL = original; self.openNative(original)
            } else { self.seek(self.position); self.play() }
        }
        cast.onFailure = { [weak self] message in self?.notice = message }
    }
    func stop() {
        guard !stopped else { return }
        subtitleDiscoveryTask?.cancel(); subtitleDiscoveryTask = nil
        metricsTask?.cancel(); metricsTask = nil; diagnostics?.event("stop", ["position": position])
        stopped = true; cacheLease?.release(); cacheLease = nil; endTemporarySpeed(); persist(); nativePlayer.pause()
        pipController?.stopPictureInPicture(); pipController = nil; player.stop(); player.drawable = nil
        server?.stop(); server = nil
        if !casting { networkServer?.stop() }; networkServer = nil
        GoogleCastPlayback.shared.clear()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }; notificationTokens = []
        for (command, target) in remoteTargets { command.removeTarget(target) }; remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.isIdleTimerDisabled = previousIdleDisabled
        AppOrientationController.shared.endPlayback()
    }
    private func installSystemControls() {
        guard notificationTokens.isEmpty else { return }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.diagnostics?.event("audio_interruption", ["type": Double(raw ?? 0), "options": Double(options)])
                if raw == AVAudioSession.InterruptionType.began.rawValue { self.interruptionWasPlaying = self.playing; self.pause() }
                else if self.interruptionWasPlaying, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.play() }
            }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in self?.diagnostics?.event("audio_route_change", ["reason": Double(reason ?? 0)]) }
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor [weak self] in self?.pause() } }
        })
        let commands = MPRemoteCommandCenter.shared()
        remoteTargets.append((commands.playCommand, commands.playCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in self?.play() }; return .success }))
        remoteTargets.append((commands.pauseCommand, commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in self?.pause() }; return .success }))
        remoteTargets.append((commands.togglePlayPauseCommand, commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in self?.toggle() }; return .success }))
        remoteTargets.append((commands.changePlaybackPositionCommand, commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor [weak self] in self?.seek(position) }; return .success
        }))
        commands.skipForwardCommand.preferredIntervals = [15]; commands.skipBackwardCommand.preferredIntervals = [15]
        remoteTargets.append((commands.skipForwardCommand, commands.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in guard let self else { return }; self.seek(self.position + 15) }; return .success }))
        remoteTargets.append((commands.skipBackwardCommand, commands.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in guard let self else { return }; self.seek(self.position - 15) }; return .success }))
    }
    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: catalogRequest?.displayTitle ?? current.title,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0]
    }
}

enum CaptionTimeline {
    static func text(at time: Double, cues: [SubtitleCue]) -> String {
        guard time.isFinite, !cues.isEmpty else { return "" }
        var low = 0, high = cues.count
        while low < high { let middle = (low + high) / 2; if cues[middle].startTime <= time { low = middle + 1 } else { high = middle } }
        // Future cues are excluded; retain older long-running captions even
        // when many shorter dialogue cues overlap them.
        return cues[..<low].filter { $0.endTime > time }.map(\.text).joined(separator: "\n")
    }
    static func timestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(seconds)) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
    static func webVTT(_ cues: [SubtitleCue], delay: Double) -> Data {
        func time(_ seconds: Double) -> String {
            let ms = max(0, Int(seconds * 1000)); return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return Data(("WEBVTT\n\n" + cues.map { "\(time($0.startTime + delay)) --> \(time($0.endTime + delay))\n\($0.text)\n" }.joined(separator: "\n")).utf8)
    }
}

struct TelegramPlayerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var nextSourcesRequest: PlaybackRequest?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: TelegramPlayerSession
    @State private var controlsVisible = true
    @State private var controlsLocked = false
    @State private var seeking = false
    @State private var seekPosition: Double = 0
    @State private var settings = false
    @State private var subtitlePicker = false
    @State private var feedback: String?
    @State private var interaction = UUID()
    @State private var captionStyle = SystemCaptionStyle.current()
    init(media: TelegramMedia, store: TelegramStore, queue: [TelegramMedia] = [], catalogRequest: PlaybackRequest? = nil, library: LibraryStore? = nil, rememberPlayback: Bool = true, headers: [String: String] = [:], nextCatalogRequest: PlaybackRequest? = nil) {
        let session = TelegramPlayerSession(media: media, store: store, queue: queue, catalogRequest: catalogRequest, library: library, rememberPlayback: rememberPlayback)
        session.sourceHeaders = headers
        session.nextCatalogRequest = nextCatalogRequest
        _session = State(initialValue: session)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if session.useNative {
                    TelegramNativePlayerController(session: session, onDoubleTap: doubleTap, onHold: hold, onTap: toggleControls)
                        .ignoresSafeArea()
                } else {
                    TelegramVideoSurface(session: session)
                        .frame(width: videoFrame(in: geometry.size).width, height: videoFrame(in: geometry.size).height)
                    PlayerGestureSurface(onTap: toggleControls, onDoubleTap: doubleTap, onHold: hold, onZoom: { session.fitToFill = $0; touch() }).ignoresSafeArea()
                }
                if !session.subtitleText.isEmpty {
                    VStack { Spacer(); DeviceCaptionOverlay(text: session.subtitleText, style: captionStyle.sized(for: videoFrame(in: geometry.size)))
                        .frame(maxWidth: min(800, geometry.size.width * 0.88)).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(uiColor: captionStyle.window), in: RoundedRectangle(cornerRadius: 5))
                        .padding(.bottom, captionBottom(in: geometry.size))
                    }.allowsHitTesting(false)
                }
                if session.casting {
                    VStack(spacing: 14) { Image(systemName: "tv.fill").font(.system(size: 54)); Text("Playing on your Cast device").font(.headline) }.foregroundStyle(.white).allowsHitTesting(false)
                }
                if !session.useNative, (controlsVisible || session.userPaused || session.opening), !controlsLocked {
                    VStack(spacing: 0) {
                        header.padding(.top, max(geometry.safeAreaInsets.top, viewportInsets.top))
                        Spacer()
                        if !session.useNative {
                            HStack(spacing: geometry.size.width > 600 ? 70 : 40) {
                                transportButton("gobackward.15", label: "Back 15 seconds") { session.seek(session.position - 15); showFeedback("−15 seconds") }
                                Image(systemName: session.playing ? "pause.fill" : "play.fill")
                                    .font(.system(size: 38, weight: .semibold)).frame(width: 88, height: 88)
                                    .modifier(PlayerGlass(circle: true)).contentShape(Circle())
                                    .gesture(TapGesture(count: 2).onEnded { session.toggle(); touch() }
                                        .exclusively(before: TapGesture().onEnded { session.toggle(); touch() }))
                                    .accessibilityAddTraits(.isButton).accessibilityAction { session.toggle(); touch() }
                                    .accessibilityLabel(session.playing ? "Pause" : "Play").accessibilityIdentifier("player.playPause")
                                transportButton("goforward.15", label: "Forward 15 seconds") { session.seek(session.position + 15); showFeedback("+15 seconds") }
                            }.transition(.opacity)
                        }
                        Spacer()
                        if !session.useNative { timeline.padding(.horizontal, geometry.size.width > 600 ? 40 : 20).padding(.bottom, max(12, max(geometry.safeAreaInsets.bottom, viewportInsets.bottom))) }
                    }.background {
                        VStack { LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140); Spacer(); if !session.useNative { LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: 180) } }.ignoresSafeArea().allowsHitTesting(false)
                    }.transition(.opacity)
                }
                if !controlsLocked, !session.opening, session.failure == nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            if let segment = session.skipSegments.first(where: { $0.contains(session.position) }) {
                                PlaybackEpisodeActionButton(title: segment.kind == .outro && session.nextCatalogRequest != nil ? "Next Episode" : "Skip " + (segment.kind == .outro ? "Credits" : segment.kind.rawValue.capitalized)) {
                                    if segment.kind == .outro, session.nextCatalogRequest != nil { openNextEpisode() }
                                    else { session.seek(segment.end); touch() }
                                }.accessibilityIdentifier("player.skipSegment")
                            } else if session.nextCatalogRequest != nil, PlaybackCompletionPolicy.shouldOfferNextEpisode(position: session.position, duration: session.duration) {
                                PlaybackEpisodeActionButton(title: "Next Episode", action: openNextEpisode)
                                    .accessibilityIdentifier("player.nextEpisodePrompt")
                            }
                        }
                    }.padding(.leading, 28).padding(.trailing, 28).padding(.bottom, 136)
                }
                if session.useNative, controlsVisible, !controlsLocked, !session.opening, session.failure == nil {
                    HStack {
                        Spacer()
                        Button(action: openPlaybackSettings) {
                            Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                        }.buttonStyle(.plain).modifier(PlayerGlass(circle: true))
                            .contentShape(Circle())
                            .highPriorityGesture(TapGesture().onEnded(openPlaybackSettings))
                            .opacity(0.86).accessibilityLabel("Playback settings").accessibilityIdentifier("player.settings")
                            .padding(.trailing, max(geometry.safeAreaInsets.trailing, viewportInsets.right) + 14)
                    }.transition(.opacity)
                }
                if controlsLocked {
                    VStack { HStack { Spacer(); Button { controlsLocked = false; controlsVisible = true; touch() } label: { Label("Unlock", systemImage: "lock.fill").padding(12).background(.ultraThinMaterial, in: Capsule()) }.accessibilityIdentifier("player.unlock") }; Spacer() }.padding()
                }
                if session.opening {
                    VStack(spacing: 10) {
                        ProgressView(session.opening ? "Opening media…" : "Buffering…").tint(.white)
                        if session.current.remoteURL == nil {
                            Text(session.transfer.summary).font(.caption.monospacedDigit())
                            if session.transfer.total > 0 {
                                ProgressView(value: Double(session.transfer.downloaded), total: Double(session.transfer.total)).frame(width: 220).tint(.white)
                            }
                            Text(session.transfer.waitingReads > 0 ? "Waiting for requested file bytes" : "Preparing playback").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).allowsHitTesting(false)
                }
                if session.buffering && !session.opening {
                    VStack { HStack {
                        ProgressView().tint(.white)
                        Text(session.transfer.summary).font(.caption2.monospacedDigit())
                        Spacer()
                    }.padding(10).background(.ultraThinMaterial, in: Capsule()).padding(.horizontal, 20)
                    Spacer()
                    }.padding(.top, viewportInsets.top + 68).allowsHitTesting(false)
                }
                if let feedback {
                    Text(feedback).font(.headline.monospacedDigit()).padding(.horizontal, 20).padding(.vertical, 12).background(.ultraThinMaterial, in: Capsule()).allowsHitTesting(false)
                }
                if session.temporaryRate {
                    VStack { Text("2× speed · release to return").font(.caption.bold()).padding(10).background(.ultraThinMaterial, in: Capsule()); Spacer() }.padding(.top, 80).allowsHitTesting(false)
                }
                if let failure = session.failure {
                    VStack(spacing: 18) { Image(systemName: "exclamationmark.triangle").font(.largeTitle); Text(failure).multilineTextAlignment(.center); Button("Choose another source") { dismiss() }.buttonStyle(.borderedProminent) }.padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22)).padding()
                }
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white).preferredColorScheme(.dark).statusBarHidden(!controlsVisible)
        .task { await session.start(environment: environment) }
        .task(id: session.catalogRequest?.contentID) {
            guard let request = session.catalogRequest, let library = session.library else { return }
            if let next = session.nextCatalogRequest, !library.isWatched(next) { return }
            session.nextCatalogRequest = await nextUnwatchedPlaybackRequest(after: request, environment: environment, library: library)
        }
        .task(id: session.duration > 0 && !session.opening) {
            guard let request = session.catalogRequest, session.duration > 0, !session.opening else { return }
            let segments = await environment.playbackSkipSegments(for: request, duration: session.duration)
            guard !Task.isCancelled else { return }
            session.skipSegments = segments
        }
        .onChange(of: session.playbackEnded) { _, ended in
            if ended, session.nextCatalogRequest != nil, UserDefaults.standard.object(forKey: "player.autoNext") as? Bool ?? true { openNextEpisode() }
        }
        .fullScreenCover(item: $nextSourcesRequest, onDismiss: { dismiss() }) { request in
            TitleSourcesView(request: request, nextRequest: nil)
        }
        .task(id: interaction) {
            guard session.playing || session.useNative, !UIAccessibility.isVoiceOverRunning else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, !seeking, !settings, !session.temporaryRate { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false } }
        }
        .onChange(of: session.playing) { _, playing in if !playing && session.userPaused { controlsVisible = true }; touch() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.endTemporarySpeed() } else { captionStyle = .current(); session.refreshCaptionAppearance() } }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String))) { _ in captionStyle = .current(); session.refreshCaptionAppearance() }
        .onDisappear { session.stop() }
        .sheet(isPresented: $settings, onDismiss: { controlsVisible = true; touch() }) { TelegramPlaybackSettings(session: session) }
        .sheet(isPresented: $subtitlePicker, onDismiss: touch) { TelegramPlaybackSettings(session: session, subtitlesOnly: true) }
        .alert("Playback", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) { Button("OK") { session.notice = nil } } message: { Text(session.notice ?? "") }
    }
    private func openPlaybackSettings() { settings = true; touch() }
    private func openNextEpisode() {
        guard nextSourcesRequest == nil, let request = session.prepareForNextCatalogEpisode() else { return }
        nextSourcesRequest = request
    }
    private var viewportInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets ?? .zero
    }
    private func videoFrame(in size: CGSize) -> CGSize {
        guard !session.fitToFill, session.videoDimensions.width > 0, session.videoDimensions.height > 0 else { return size }
        let factor = min(size.width / session.videoDimensions.width, size.height / session.videoDimensions.height)
        return CGSize(width: session.videoDimensions.width * factor, height: session.videoDimensions.height * factor)
    }
    private func captionBottom(in size: CGSize) -> CGFloat {
        let video = session.useNative ? session.nativePlayer.currentItem?.presentationSize ?? .zero : session.videoDimensions
        guard video.width > 0, video.height > 0, !session.fitToFill else { return controlsVisible && !session.useNative ? 135 : 40 }
        let height = min(size.height, size.width * video.height / video.width)
        return max((size.height - height) / 2 + 12, size.width > size.height && controlsVisible ? 110 : 28)
    }
    private var headerTitle: String { session.catalogRequest?.media.title ?? session.current.title }
    private var headerEpisode: String? {
        if let episode = session.catalogRequest?.episode { return String(format: "S%02dE%02d", episode.seasonNumber, episode.number) }
        return session.current.episode.map { String(format: "S%02dE%02d", $0.season, $0.episode) }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44).modifier(PlayerGlass(circle: true)) }.accessibilityLabel("Close player")
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle).font(.headline).lineLimit(1)
                if let episode = headerEpisode { Text(episode).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7)) }
            }
            Spacer(minLength: 4)
            if session.catalogRequest == nil, session.next != nil {
                Button { if session.catalogRequest != nil { openNextEpisode() } else { Task { await session.playQueueNext() } }; touch() } label: {
                    Image(systemName: "forward.end.fill").frame(width: 44, height: 44).modifier(PlayerGlass(circle: true))
                }.accessibilityLabel("Next episode").accessibilityIdentifier("player.nextEpisode")
            }
            GoogleCastRouteButton(onTap: touch).frame(width: 40, height: 40)
            PlayerAirPlayButton(video: session.useNative, onPresent: { touch(); Task { await session.prepareAirPlay() } }).frame(width: 40, height: 40)
            Button { settings = true; touch() } label: { Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44).modifier(PlayerGlass(circle: true)) }.accessibilityLabel("Playback settings").accessibilityIdentifier("player.settings")
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
    private var timeline: some View {
        VStack(alignment: .trailing, spacing: 14) {
            HStack(spacing: 20) {
                Menu {
                    Button("Off", systemImage: session.subtitleName == "Off" ? "checkmark" : "captions.bubble.slash") { session.selectSubtitle(nil) }
                    ForEach(session.textTracks) { track in
                        Button(track.name.isEmpty ? "Subtitle track" : track.name, systemImage: track.selected ? "checkmark" : "captions.bubble") { session.selectSubtitle(track.id) }
                    }
                    Divider()
                    Button("Find or import subtitles…", systemImage: "plus") { subtitlePicker = true }
                } label: { Image(systemName: "captions.bubble") }.accessibilityLabel("Choose subtitles").accessibilityIdentifier("player.subtitles")
                Button { session.fitToFill.toggle(); touch() } label: { Image(systemName: session.fitToFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.accessibilityLabel(session.fitToFill ? "Fit video" : "Fill screen")
                Button { session.startPictureInPicture(); touch() } label: { Image(systemName: "pip.enter") }.disabled(!session.canPictureInPicture).accessibilityLabel("Picture in Picture")
                Spacer(minLength: 0)
                Button { controlsLocked = true; session.endTemporarySpeed() } label: { Image(systemName: "lock.open") }.accessibilityLabel("Lock controls")
                Menu {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in Button(String(format: "%.2g×", speed)) { session.setRate(speed); touch() } }
                } label: { Text(String(format: "%.2g×", session.rate)).font(.subheadline.bold()) }.accessibilityLabel("Playback speed")
            }.font(.title3).frame(height: 32)
                .overlay { PlayerVolumeSlider().frame(width: 120, height: 30).allowsHitTesting(true) }
                .padding(.horizontal, 18).padding(.vertical, 10).modifier(PlayerGlass())
            HStack(spacing: 12) {
                Text(CaptionTimeline.timestamp(seeking ? seekPosition : session.position)).frame(minWidth: 34)
                Slider(value: Binding(get: { seeking ? seekPosition : session.position }, set: { seekPosition = $0 }), in: 0...max(1, session.duration)) { editing in
                    seeking = editing; touch(); if !editing { session.seek(seekPosition) }
                }.tint(.white).controlSize(.mini).disabled(session.duration <= 0)
                    .accessibilityLabel("Playback position").accessibilityIdentifier("player.timeline")
                    .accessibilityValue(CaptionTimeline.timestamp(seeking ? seekPosition : session.position))
                Text("−" + CaptionTimeline.timestamp(max(0, session.duration - session.position))).frame(minWidth: 40)
            }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 16).padding(.vertical, 8).modifier(PlayerGlass())
        }
    }
    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button { action(); touch() } label: { Image(systemName: symbol).font(.system(size: 32, weight: .medium)).frame(width: 56, height: 56) }.modifier(PlayerGlass(circle: true)).accessibilityLabel(label)
    }
    private func touch() { interaction = UUID() }
    private func toggleControls() { guard !controlsLocked else { return }; withAnimation(.easeInOut(duration: 0.18)) { controlsVisible.toggle() }; touch() }
    private func doubleTap(_ fraction: CGFloat) {
        guard !controlsLocked else { return }
        let interval = PlaybackGesturePreferences.skipInterval()
        if fraction < 0.32 { session.seek(session.position - interval); showFeedback("−\(Int(interval)) seconds") }
        else if fraction > 0.68 { session.seek(session.position + interval); showFeedback("+\(Int(interval)) seconds") }
        else { session.toggle(); showFeedback(session.playing ? "Play" : "Pause") }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(); touch()
    }
    private func hold(_ active: Bool) {
        if active, !controlsLocked { session.beginTemporarySpeed(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        else { session.endTemporarySpeed() }; touch()
    }
    private func showFeedback(_ text: String) {
        feedback = text
        Task { try? await Task.sleep(for: .seconds(0.8)); if feedback == text { feedback = nil } }
    }
}

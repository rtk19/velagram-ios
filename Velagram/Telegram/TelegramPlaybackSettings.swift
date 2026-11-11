import SwiftUI

struct TelegramPlaybackSettings: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: TelegramPlayerSession
    var subtitlesOnly = false
    @State private var importing = false
    @State private var studio = false
    @State private var online: [SubtitleSource] = []
    @State private var searching = false
    @State private var loadingID: String?
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Subtitles") {
                    Text("Selected: \(session.subtitleName)").font(.caption).foregroundStyle(.secondary)
                    Button("Off") { session.selectSubtitle(nil) }
                    ForEach(session.textTracks) { track in
                        Button { session.selectSubtitle(track.id) } label: { HStack { Text(track.name.isEmpty ? "Subtitle track" : track.name); Spacer(); if track.selected { Image(systemName: "checkmark") } } }
                    }
                    Button("Open subtitle file…") { importing = true }
                    if session.catalogRequest != nil {
                        Button { Task { await findOnline() } } label: { HStack { Text("Find subtitles online"); if searching { Spacer(); ProgressView() } } }.disabled(searching)
                    }
                    ForEach(online) { source in
                        Button { Task { await load(source) } } label: {
                            VStack(alignment: .leading) { Text(source.label).font(.subheadline); Text([source.providerName, source.languageCode].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }.disabled(loadingID != nil)
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Text("Caption appearance follows Settings → Accessibility → Subtitles & Captioning. Image-based subtitle tracks keep their original artwork.").font(.caption).foregroundStyle(.secondary)
                    if !session.useNative || session.hasExternalSubtitles {
                        LabeledContent("Subtitle delay", value: String(format: "%+.2f s", session.subtitleDelay))
                        Slider(value: $session.subtitleDelay, in: -10...10, step: 0.1).onChange(of: session.subtitleDelay) { _, _ in session.applyTiming() }
                        if session.hasExternalSubtitles {
                            Button("Subtitle Studio") { studio = true }
                        }
                        Button("Reset subtitle timing") { session.subtitleDelay = 0; session.applyTiming() }
                    }
                }
                if !subtitlesOnly {
                Section("Audio") {
                    ForEach(session.audioTracks) { track in
                        Button { session.selectAudio(track.id) } label: { HStack { Text(track.name.isEmpty ? "Audio track" : track.name); Spacer(); if track.selected { Image(systemName: "checkmark") } } }
                    }
                    if !session.useNative {
                        LabeledContent("Audio delay", value: String(format: "%+.2f s", session.audioDelay))
                        Slider(value: $session.audioDelay, in: -3...3, step: 0.05).onChange(of: session.audioDelay) { _, _ in session.applyTiming() }
                        Button("Reset audio sync") { session.audioDelay = 0; session.applyTiming() }
                    }
                    Text("Audio and video use the same playback clock. Adjust delay only if this particular release is out of sync.").font(.caption).foregroundStyle(.secondary)
                }
                Section("TV playback") {
                    Text(session.useNative ? "AirPlay video and Picture in Picture use Apple's native player. Cast playback depends on the formats supported by your TV." : "For AirPlay video, choose an MP4/HLS release or use iOS Screen Mirroring. This release uses VLC; Cast playback depends on your TV's codec support.").font(.caption).foregroundStyle(.secondary)
                    Text("Keep Velagram open while sending Telegram or relayed media to a TV.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Playback diagnostics") {
                    Text(session.transfer.summary).font(.caption.monospacedDigit())
                    LabeledContent("Delivered to player", value: ByteCountFormatter.string(fromByteCount: session.transfer.delivered, countStyle: .file))
                    LabeledContent("Waiting reads", value: String(session.transfer.waitingReads))
                    Text("Cached bytes are the downloaded parts of this file, including earlier cached data; they do not represent playable time ahead.").font(.caption).foregroundStyle(.secondary)
                    if let url = session.diagnosticsURL { ShareLink("Export playback log", item: url) }
                }
                Section("Playback") {
                    DoubleTapSkipSettings()
                    Picker("Speed", selection: Binding(get: { session.rate }, set: { session.setRate($0) })) {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) }
                    }
                    Toggle("Fill screen", isOn: $session.fitToFill)
                    Menu("Sleep timer") {
                        ForEach([15, 30, 60, 90], id: \.self) { minutes in Button("\(minutes) minutes") { session.sleepDeadline = Date().addingTimeInterval(Double(minutes * 60)) } }
                        Button("Off") { session.sleepDeadline = nil }
                    }
                    if let end = session.sleepDeadline { LabeledContent("Pause at", value: end.formatted(date: .omitted, time: .shortened)) }
                    Text("Hold the video for temporary 2× speed. Double-tap the center to play/pause, or either side to seek by your selected skip interval. Pinch to fit or fill.").font(.caption).foregroundStyle(.secondary)
                }
                }
            }.navigationTitle(subtitlesOnly ? "Subtitles" : "Playback settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $studio) { TelegramSubtitleStudio(session: session) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do { try session.importSubtitle(result.get()); message = nil }
            catch { message = error.localizedDescription }
        }
    }
    private func findOnline() async {
        guard let original = session.catalogRequest else { return }; searching = true; message = nil; defer { searching = false }
        let request = await environment.canonicalPlaybackRequest(for: original)
        let lookup = request.subtitleLookupRequest ?? SubtitleLookupRequest(kind: request.media.kind, imdbID: "", seasonNumber: request.episode?.seasonNumber, episodeNumber: request.episode?.number, title: request.media.title)
        let settings = [("subdl", "subdl"), ("wizdom", "wizdom"), ("ktuvit", "ktuvit"), ("external-stream-subtitles", "externalStreams")]
        let enabled = Set(settings.filter { UserDefaults.standard.object(forKey: "subtitle.provider.\($0.1).enabled") as? Bool ?? true }.map(\.0))
        online = await environment.subtitleRegistry.subtitles(for: lookup, fallbackTMDbID: request.media.tmdbID, enabledProviderIDs: enabled)
        if online.isEmpty { message = "No online subtitles found for this title and episode. You can open an SRT or WebVTT file instead." }
    }
    private func load(_ source: SubtitleSource) async {
        loadingID = source.id; message = "Loading subtitles…"; defer { loadingID = nil }
        do {
            var request = URLRequest(url: source.url)
            source.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let response = try await SubtitleResourceRetry.load(request: request, client: HTTPClient())
            let cues = try SubtitleParser.cues(from: response.data, languageCode: source.languageCode)
            session.setExternalSubtitles(SubtitleDirectionFormatter.normalizedCues(cues, languageCode: source.languageCode), name: source.label, source: source)
            message = "Subtitles ready"; dismiss()
        } catch { message = "These subtitles could not be loaded. Try another release or open a subtitle file." }
    }
}

private struct TelegramSubtitleStudio: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: TelegramPlayerSession
    @State private var message: String?
    private var versions: [SubtitleSyncVersion] {
        guard let request = session.catalogRequest, let source = session.externalSubtitleSource else { return [] }
        return session.library?.subtitleSyncVersions(for: request).filter { source.matchesSyncKey($0.subtitleKey) } ?? []
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Preview & timing") {
                    Text(session.subtitleText.isEmpty ? "No caption at the current position" : session.subtitleText)
                    LabeledContent("Offset", value: String(format: "%+.1f s", session.subtitleDelay))
                    HStack {
                        Button("Earlier −0.1s") { adjust(-0.1) }
                        Spacer()
                        Button("Later +0.1s") { adjust(0.1) }
                    }.buttonStyle(.bordered)
                    Slider(value: $session.subtitleDelay, in: -300...300, step: 0.1)
                        .onChange(of: session.subtitleDelay) { _, _ in session.applyTiming() }
                    Button(session.playing ? "Pause preview" : "Play preview") { session.toggle() }
                    Button("Reset offset") { session.subtitleDelay = 0; session.applyTiming() }
                    Text("Positive offsets show captions later. Tap a cue to preview it in the video.").font(.caption).foregroundStyle(.secondary)
                }
                if let request = session.catalogRequest, let source = session.externalSubtitleSource, let library = session.library {
                    Section("Saved timing versions") {
                        Button("Save current timing") {
                            if let version = library.saveSubtitleSyncVersion(subtitle: source, offset: session.subtitleDelay, for: request) {
                                library.updateSubtitleSelectionPreference(SubtitleSelectionPreference(baseSubtitleKey: source.syncKey, syncVersionID: version.id), for: request)
                                message = "Timing saved for this episode and subtitle release."
                            } else { message = "Choose a nonzero offset before saving." }
                        }
                        ForEach(versions) { version in
                            Button(version.displayName) {
                                session.subtitleDelay = version.offset; session.applyTiming()
                                library.updateSubtitleSelectionPreference(SubtitleSelectionPreference(baseSubtitleKey: source.syncKey, syncVersionID: version.id), for: request)
                            }.swipeActions { Button("Delete", role: .destructive) { library.deleteSubtitleSyncVersion(version.id, for: request) } }
                        }
                        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("Subtitle cues") {
                    ForEach(Array(session.externalCues.enumerated()), id: \.offset) { _, cue in
                        Button { session.seek(max(0, cue.startTime + session.subtitleDelay)) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(CaptionTimeline.timestamp(cue.startTime + session.subtitleDelay)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(cue.text).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }.navigationTitle("Subtitle Studio").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func adjust(_ delta: Double) {
        session.subtitleDelay = min(300, max(-300, session.subtitleDelay + delta)); session.applyTiming()
    }
}

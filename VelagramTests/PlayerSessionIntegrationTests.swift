import Foundation
import UIKit
import Testing
import AVFoundation
import VLCKit
@testable import Velagram

private final class PlayerFixtureBundle: NSObject {}
@Suite(.serialized)
struct PlayerSessionIntegrationTests {
    @MainActor private func session(container: String) throws -> TelegramPlayerSession {
        let name = container == "mp4" ? "TelegramNativePlayback" : "TelegramInteraction"
        let url = try #require(Bundle(for: PlayerFixtureBundle.self).url(forResource: name, withExtension: container))
        let media = TelegramMedia(chatID: -42, messageID: -42, fileID: nil, name: url.lastPathComponent, caption: "", date: .now,
            size: 0, duration: container == "mp4" ? 4 : 30, mimeType: "video/\(container)", thumbnailFileID: nil, kind: .video, remoteURL: url)
        return TelegramPlayerSession(media: media, store: TelegramStore(transport: TelegramFixtureTransport()), queue: [], rememberPlayback: false)
    }
    @MainActor @Test func nativeEnginePlaysWithSystemTracksAndRestoresTemporarySpeed() async throws {
        let session = try session(container: "mp4")
        let task = Task { await session.start() }
        defer { task.cancel(); session.stop() }
        for _ in 0..<60 where session.position < 0.4 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(session.useNative)
        #expect(session.position >= 0.4)
        #expect(!session.audioTracks.isEmpty)
        #expect(!session.textTracks.isEmpty)
        session.setRate(1.25); session.beginTemporarySpeed()
        #expect(session.temporaryRate)
        #expect(session.nativePlayer.rate == 2)
        session.endTemporarySpeed()
        #expect(session.nativePlayer.rate == 1.25)
        #expect(session.rate == 1.25)
        session.pause(); session.beginTemporarySpeed()
        #expect(!session.temporaryRate)
        #expect(session.nativePlayer.rate == 0)
    }
    @MainActor @Test func matroskaUsesOneClockAndExposesTracksTimingAndPiPBridge() async throws {
        let session = try session(container: "mkv")
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let adapter = VLCPiPMediaController(); adapter.session = session
        session.pipAdapter = adapter; session.player.drawable = surface
        let task = Task { await session.start() }
        defer { task.cancel(); session.stop() }
        for _ in 0..<80 where session.position < 0.5 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!session.useNative)
        #expect(session.position >= 0.5)
        #expect(!session.audioTracks.isEmpty)
        #expect(!session.textTracks.isEmpty)
        session.setRate(1.5); session.beginTemporarySpeed()
        for _ in 0..<20 where session.player.rate != 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.player.rate == 2)
        for _ in 0..<20 where session.appliedRate != 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.appliedRate == 2)
        session.endTemporarySpeed()
        for _ in 0..<20 where session.player.rate != 1.5 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.player.rate == 1.5)
        for _ in 0..<20 where session.appliedRate != 1.5 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.appliedRate == 1.5)
        session.setRate(1)
        session.audioDelay = 0.25; session.subtitleDelay = -0.5; session.applyTiming()
        #expect(session.player.currentAudioPlaybackDelay == 250_000)
        #expect(session.player.currentVideoSubTitleDelay == -500_000)
        session.seek(15)
        for _ in 0..<60 where Double(adapter.mediaTime()) / 1000 < 14 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(Double(adapter.mediaTime()) / 1000 >= 14)
        session.pause(); session.seek(10)
        try await Task.sleep(for: .milliseconds(700))
        #expect(!session.player.isPlaying)
        session.play()
        for _ in 0..<40 where session.position < 10.3 || session.position > 13 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(session.player.isPlaying)
        #expect(session.position >= 10.3 && session.position < 14)
        session.selectSubtitle(nil)
        session.setExternalSubtitles([SubtitleCue(startTime: 0, endTime: 30, text: "שלום — generated subtitle")], name: "Hebrew fixture")
        #expect(session.hasExternalSubtitles)
        #expect(session.subtitleName == "Hebrew fixture")
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.subtitleText.contains("שלום"))
        #expect(session.player.textTracks.allSatisfy { !$0.isSelected })
    }
    @MainActor @Test(arguments: [false, true]) func fullHDAC3SurroundUsesDefaultVLCClock(streamed: Bool) async throws {
        let url = try #require(Bundle(for: PlayerFixtureBundle.self).url(forResource: "TelegramSurroundPlayback", withExtension: "mkv"))
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let file = TelegramJSON.request("file", ["id": .integer(1), "size": .integer(size), "local": .object([
            "path": .string(url.path), "is_downloading_completed": .bool(true), "downloaded_size": .integer(size)])])
        let transport = TelegramFixtureTransport { _ in file }
        let source = TelegramMedia(chatID: -43, messageID: -43, fileID: 1, name: url.lastPathComponent, caption: "", date: .now,
            size: size, duration: 12, mimeType: "video/x-matroska", thumbnailFileID: nil, kind: .video, remoteURL: nil)
        let server = streamed ? try TelegramStreamServer(transport: transport, media: source) : nil
        defer { server?.stop() }
        let playbackURL: URL
        if let server { playbackURL = try await server.start(filename: source.name) } else { playbackURL = url }
        let media = TelegramMedia(chatID: -43, messageID: -43, fileID: nil, name: url.lastPathComponent, caption: "", date: .now,
            size: size, duration: 12, mimeType: "video/x-matroska", thumbnailFileID: nil, kind: .video, remoteURL: playbackURL)
        let session = TelegramPlayerSession(media: media, store: TelegramStore(transport: TelegramFixtureTransport()), queue: [], rememberPlayback: false)
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180)); session.player.drawable = surface
        let task = Task { await session.start() }
        defer { task.cancel(); session.stop() }
        for _ in 0..<100 where session.position < 1.2 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!session.useNative)
        #expect(session.position >= 1.2)
        #expect(session.player.videoSize == CGSize(width: 1920, height: 1080))
        #expect(!session.audioTracks.isEmpty)
        let statistics = try #require(session.player.media?.statistics)
        #expect(statistics.decodedVideo > 0)
        #expect(statistics.decodedAudio > 0)
        #expect(statistics.lostAudioBuffers == 0)
        let initialPosition = session.position
        try await Task.sleep(for: .seconds(3))
        #expect(session.position >= initialPosition + 2, "Playback must continue after startup through the production session.")
        #expect(session.failure == nil)
        #expect(!session.buffering)
        #expect(session.player.media?.statistics.lostAudioBuffers == 0)
    }

}

@Suite("Catalog playback parity", .serialized)
struct CatalogPlaybackParityTests {
    @Test(arguments: [0.0, 900, 1739, 1740, 1799])
    func nextEpisodePromptOnlyAppearsInFinalMinute(position: Double) {
        #expect(PlaybackCompletionPolicy.shouldOfferNextEpisode(position: position, duration: 1800) == (position >= 1740))
        #expect(!PlaybackCompletionPolicy.shouldOfferNextEpisode(position: position, duration: .nan))
        #expect(!PlaybackCompletionPolicy.shouldOfferNextEpisode(position: position, duration: 0))
    }

    @MainActor @Test func doubleTapSkipPreferenceDefaultsAndClamps() throws {
        let suite = "skip-preference-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PlaybackGesturePreferences.skipInterval(defaults: defaults) == 15)
        for value in [5.0, 10, 15, 30, 60] {
            defaults.set(value, forKey: PlaybackGesturePreferences.skipIntervalKey)
            #expect(PlaybackGesturePreferences.skipInterval(defaults: defaults) == value)
        }
        defaults.set(100.0, forKey: PlaybackGesturePreferences.skipIntervalKey)
        #expect(PlaybackGesturePreferences.skipInterval(defaults: defaults) == 60)
        defaults.set(0.0, forKey: PlaybackGesturePreferences.skipIntervalKey)
        #expect(PlaybackGesturePreferences.skipInterval(defaults: defaults) == 5)
    }

    @MainActor @Test func completionPromotesNextEpisodeWithoutOverwritingAnotherEpisode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        let show = MediaItem(id: "parity-show", providerID: "test", kind: .series, title: "Parity")
        func request(_ number: Int) -> PlaybackRequest {
            PlaybackRequest(media: show, episode: MediaEpisode(id: "parity-\(number)", providerID: "test", showID: show.id, seasonNumber: 1, number: number, title: nil, overview: nil, posterURL: nil))
        }
        let first = request(1), second = request(2), third = request(3)
        library.updateProgress(request: third, position: 300, duration: 1800)
        let media = TelegramMedia(chatID: 0, messageID: 0, fileID: nil, name: "episode.mp4", caption: "", date: .now, size: 0, duration: 1800, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: URL(string: "https://example.com/episode.mp4"))
        let session = TelegramPlayerSession(media: media, store: TelegramStore(transport: TelegramFixtureTransport()), queue: [], catalogRequest: first, library: library)
        session.nextCatalogRequest = second
        session.recordCatalogProgress(position: 1739, duration: 1800)
        #expect(!library.isWatched(first))
        session.recordCatalogProgress(position: 1740, duration: 1800)
        #expect(library.isWatched(first))
        #expect(!library.isWatched(second))
        #expect(library.resumePosition(for: third) == 300)
        #expect(library.progress.first?.episode?.id == second.episode?.id)
        session.recordCatalogProgress(position: 1750, duration: 1800)
        #expect(library.progress(for: first) == nil)
        #expect(library.resumePosition(for: third) == 300)
        session.nativePlayer.replaceCurrentItem(with: AVPlayerItem(url: URL(string: "https://example.com/episode.mp4")!))
        let next = session.prepareForNextCatalogEpisode()
        #expect(next == second)
        #expect(session.nativePlayer.currentItem == nil)
        #expect(session.nativePlayer.rate == 0)
        #expect(session.player.media == nil)
        session.stop() // Dismissal after the handoff is safe and idempotent.
    }

    @MainActor @Test func studioVersionRestoresForTheSameSubtitleRelease() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        let request = PlaybackRequest(media: MediaItem(id: "studio-movie", providerID: "test", kind: .movie, title: "Studio"), episode: nil)
        let source = SubtitleSource(id: "stable-release", providerID: "test", providerName: "Test", label: "English", languageCode: "en", url: URL(string: "https://example.com/subtitle.srt")!)
        let version = try #require(library.saveSubtitleSyncVersion(subtitle: source, offset: 2.5, for: request))
        library.updateSubtitleSelectionPreference(SubtitleSelectionPreference(baseSubtitleKey: source.syncKey, syncVersionID: version.id), for: request)
        let restored = LibraryStore(directory: root)
        let media = TelegramMedia(chatID: 0, messageID: 0, fileID: nil, name: "movie.mp4", caption: "", date: .now, size: 0, duration: 1800, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: URL(string: "https://example.com/movie.mp4"))
        let session = TelegramPlayerSession(media: media, store: TelegramStore(transport: TelegramFixtureTransport()), queue: [], catalogRequest: request, library: restored)
        let cues = [SubtitleCue(startTime: 10, endTime: 12, text: "Caption")]
        session.setExternalSubtitles(cues, name: source.label, source: source)
        #expect(session.subtitleDelay == 2.5)
        #expect(CaptionTimeline.text(at: 12.6 - session.subtitleDelay, cues: session.externalCues) == "Caption")
        #expect(restored.subtitleVisibilityPreference(for: request) == true)
    }

    @MainActor @Test func catalogPreferencesAreSharedWithWebPlayer() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        let request = PlaybackRequest(media: MediaItem(id: "parity-movie", providerID: "test", kind: .movie, title: "Parity"), episode: nil)
        let media = TelegramMedia(chatID: 0, messageID: 0, fileID: nil, name: "movie.mp4", caption: "", date: .now, size: 0, duration: 1800, mimeType: "video/mp4", thumbnailFileID: nil, kind: .video, remoteURL: URL(string: "https://example.com/movie.mp4"))
        let session = TelegramPlayerSession(media: media, store: TelegramStore(transport: TelegramFixtureTransport()), queue: [], catalogRequest: request, library: library)
        session.setRate(1.5)
        session.fitToFill = true
        session.selectSubtitle(nil)
        #expect(library.playbackRate(for: request, defaultRate: 1) == 1.5)
        #expect(library.isPlayerZoomedToFill(for: request))
        #expect(library.subtitleVisibilityPreference(for: request) == false)
    }
}

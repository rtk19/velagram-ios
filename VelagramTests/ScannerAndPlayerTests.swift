import Foundation
import Testing
@testable import Velagram

struct ScannerAndPlayerTests {
    @Test @MainActor func fastSourcePublishesWhileTelegramIsStillStarting() async throws {
        let transport = ScannerStartupGate()
        let store = TelegramStore(transport: transport)
        let model = TitleSourcesModel()
        let context = PlaybackLookupContext(request: PlaybackDiscoveryTests.request)
        let scan = Task { await model.scan(context: context, providers: [ScannerFastProvider()], store: store, pages: 2) }
        // Telegram remains suspended until the assertions have inspected the UI model.
        for _ in 0..<100 where !model.web.contains(where: { $0.id == "scanner-fast" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.web.contains { $0.id == "scanner-fast" })
        #expect(model.searching)
        #expect(model.statuses["scanner-fast"] == "1 sources")
        scan.cancel()
        await transport.release()
        await scan.value
        #expect(!model.searching)
    }

    private func item(_ name: String, size: Int64 = 88_200_000, id: Int64 = 1, caption: String = "") -> TelegramMedia {
        TelegramMedia(chatID: id, messageID: id, fileID: Int(id), name: name, caption: caption, date: Date(timeIntervalSince1970: Double(id)), size: size,
            duration: 1200, mimeType: "video/x-matroska", thumbnailFileID: nil, kind: .video, remoteURL: nil)
    }
    private var himym: PlaybackLookupContext {
        let media = MediaItem(id: "1100", providerID: "tmdb", kind: .series, title: "How I Met Your Mother", originalTitle: "How I Met Your Mother", tmdbID: 1100)
        let ep = MediaEpisode(id: "s6e14", providerID: "tmdb", showID: "1100", seasonNumber: 6, number: 14, title: nil, overview: nil, posterURL: nil)
        var context = PlaybackLookupContext(request: PlaybackRequest(media: media, episode: ep)); context.alternativeTitles = ["איך פגשתי את אמא"]
        return context
    }
    @Test(arguments: ["How.I.Met.Your.Mother.S06E14.mkv", "HIMYM.s6e14.720p.mkv", "H.I.M.Y.M.S06E14.Web-DL.mkv", "איך פגשתי את אמא עונה 6 פרק 14.mkv", "איך_פגשתי_את_אמא_ע6פ14_720p.mkv", "איך פגשתי את אמא, עונה 6, פרק 14ת.mkv", "How I Met Your Mother season 6 episode 14.mkv", "HIMYM S 6 , E 14.mkv", "HIMYM 6x14.mkv"])
    func findsRequestedEpisodeAcrossLanguagesAndFormats(_ name: String) {
        #expect(TelegramCatalogMatching.score(item(name), context: himym) != nil)
    }
    @Test func neverMixesSeasonsOrEpisodesWhenUsingAbbreviations() {
        #expect(TelegramCatalogMatching.score(item("HIMYM.S05E14.mkv"), context: himym) == nil)
        #expect(TelegramCatalogMatching.score(item("HIMYM.S06E15.mkv"), context: himym) == nil)
        #expect(TelegramCatalogMatching.score(item("Another.Show.S06E14.mkv"), context: himym) == nil)
        #expect(TelegramCatalogMatching.score(item("פרק 14.mkv"), context: himym, chatTitle: "איך פגשתי את אמא עונה 6") != nil)
        #expect(TelegramCatalogMatching.score(item("פרק 14.mkv"), context: himym, chatTitle: "איך פגשתי את אמא עונה 5") == nil)
    }
    @Test func preferredLanguageIsSearchedFirstWithoutDroppingOtherLanguage() {
        let hebrew = TelegramCatalogMatching.queries(himym, language: .hebrew)
        let english = TelegramCatalogMatching.queries(himym, language: .english)
        #expect(hebrew.first?.contains("איך פגשתי") == true)
        #expect(english.first?.contains("how i met") == true)
        #expect(Set(hebrew) == Set(english))
    }
    @Test func scanProgressCompletesAllScheduledOptions() async throws {
        let recorder = ScanProgressRecorder()
        try await TelegramCatalogSearch(transport: TelegramFixtureTransport()).search(context: himym, pages: 2, onProgress: { await recorder.append($0) }) { _ in }
        let values = await recorder.values
        let last = try #require(values.last)
        #expect(last.completed > 0)
        #expect(last.completed == last.total)
        #expect(values.allSatisfy { $0.completed <= $0.total })
        #expect(values.contains { $0.task.contains("Searching:") })
    }
    @Test func queryPlanIncludesAcronymsHebrewAndSeasonFormats() {
        let queries = TelegramCatalogMatching.queries(himym)
        #expect(queries.contains { $0 == "himym S06E14" })
        #expect(queries.contains { $0 == "h.i.m.y.m S6E14" })
        #expect(queries.contains { $0.contains("איך פגשתי את אמא") && $0.contains("ע6פ14") })
        #expect(queries.contains { $0.contains("season 6 episode 14") })
        #expect(Set(queries).count == queries.count)
    }
    @Test func identicalReleasesCollapseButKeepEveryLocationAndDifferentEncodes() {
        let media = [item("H.I.M.Y.M.S06E14.720p.mkv", id: 1), item("h_i_m_y_m_s06e14_720p.mkv", id: 2), item("H.I.M.Y.M.S06E14.720p.mkv", size: 150_000_000, id: 3), item("HIMYM.S06E14.1080p.mkv", id: 4)]
        let groups = TelegramReleaseGroup.group(media)
        #expect(groups.count == 3)
        #expect(groups.first { $0.locations.count == 2 }?.representative.messageID == 2)
        #expect(groups.flatMap(\.locations).count == 4)
        #expect(TelegramReleaseGroup.group([item("video.mp4", id: 1), item("video.mp4", id: 2)]).count == 2)
    }
    @Test func remoteFileIdentityGroupsRenamedCopies() {
        var first = item("Release.mkv"); first.remoteUniqueID = "same-file"
        var second = item("Renamed.Release.mkv", id: 2); second.remoteUniqueID = "same-file"
        #expect(TelegramReleaseGroup.group([first, second]).count == 1)
    }
    @Test func sourceSortsAndTextFilteringKeepUnknownValuesLast() {
        let high = SourceResultInfo(id: "high", title: "Release", origin: "Hebrew series", metadata: .init(origin: "Telegram", quality: "1080p", sizeBytes: 300, container: "MKV", audioLanguage: nil, releaseType: nil), date: Date(timeIntervalSince1970: 100))
        let low = SourceResultInfo(id: "low", title: "Release", origin: "Other", metadata: .init(origin: "Telegram", quality: "720p", sizeBytes: 100, container: "MP4", audioLanguage: nil, releaseType: nil), date: Date(timeIntervalSince1970: 200))
        let unknown = SourceResultInfo(id: "unknown", title: "Release", origin: "Web", metadata: nil, date: nil)
        for ascending in [true, false] {
            #expect([unknown, low, high].sorted { SourceResultInfo.ordered($0, $1, by: .size, ascending: ascending) }.last?.id == "unknown")
        }
        #expect(SourceResultInfo.ordered(high, low, by: .quality, ascending: false))
        #expect(SourceResultInfo.ordered(low, high, by: .date, ascending: false))
        #expect(high.matches("hebrew mkv 1080")); #expect(!low.matches("hebrew"))
    }
    @Test func subtitleClockHandlesPauseSeeksDelayAndOverlappingDialogue() throws {
        let cues = [SubtitleCue(startTime: 1, endTime: 3, text: "Hello"), SubtitleCue(startTime: 2, endTime: 4, text: "שלום")]
        #expect(CaptionTimeline.text(at: 0, cues: cues) == "")
        #expect(CaptionTimeline.text(at: 2.5, cues: cues) == "Hello\nשלום")
        #expect(CaptionTimeline.text(at: 4, cues: cues) == "")
        let delayed = try SubtitleParser.cues(from: CaptionTimeline.webVTT(cues, delay: 1.5))
        #expect(delayed.first?.startTime == 2.5)
        #expect(TelegramPlayerSession.prefersNative(item("Release.mp4")))
        #expect(!TelegramPlayerSession.prefersNative(item("Release.mkv")))
    }
}

private actor ScanProgressRecorder {
    var values: [TelegramScanProgress] = []
    func append(_ value: TelegramScanProgress) { values.append(value) }
}

struct PlaybackDiagnosticsTests {
    @Test func speedExcludesCachedBaselineAndExpiresWhenUpdatesStop() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = PlaybackDiagnostics(total: 1000, directory: directory)
        func file(_ bytes: Int64) throws -> TelegramFile {
            try #require(TelegramFile(.request("file", ["id": .integer(1), "size": .integer(1000), "local": .object(["downloaded_size": .integer(bytes), "is_downloading_active": .bool(true), "download_offset": .integer(512), "downloaded_prefix_size": .integer(128)])])))
        }
        diagnostics.sample(try file(100), now: 10)
        #expect(diagnostics.snapshot(now: 10).bytesPerSecond == 0)
        diagnostics.sample(try file(300), now: 12)
        #expect(diagnostics.snapshot(now: 12).bytesPerSecond == 100)
        #expect(diagnostics.snapshot(now: 16).bytesPerSecond == 0)
        let read = diagnostics.beginRead(512, count: 64)
        #expect(diagnostics.snapshot().waitingReads == 1)
        diagnostics.endRead(read)
        #expect(diagnostics.snapshot().waitingReads == 0)
        diagnostics.delivered(64)
        #expect(diagnostics.snapshot().delivered == 64)
        diagnostics.flush()
        let record = try #require(String(contentsOf: diagnostics.url, encoding: .utf8).split(separator: "\n").first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any])
        #expect(Set(json.keys) == Set(["session", "time", "event", "metrics"]))
    }
}

private struct ScannerFastProvider: PlaybackProvider {
    let id = "scanner-fast"
    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        [PlaybackDiscoveryTests.candidate(id)]
    }
}

private actor ScannerStartupGate: TelegramTransport {
    nonisolated let updates: AsyncStream<TelegramJSON> = AsyncStream { $0.finish() }
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func request(_ query: TelegramJSON, timeout: TimeInterval) async throws -> TelegramJSON {
        if !released { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
        return .request("authorizationStateWaitPhoneNumber")
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}


@Suite("Source playback history")
struct SourcePlaybackHistoryTests {
    @Test @MainActor func historyPersistsAndKeepsEveryPlayedSourceWithoutDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let request = PlaybackDiscoveryTests.request
        library.recordPlayedSource("web:first", for: request)
        library.recordPlayedSource("telegram:release", for: request)
        library.recordPlayedSource("web:first", for: request)
        library.recordPlayedSource("web:first", for: request)
        #expect(library.sourceHistory(for: request) == ["web:first", "telegram:release"])
        #expect(LibraryStore(directory: directory).sourceHistory(for: request) == ["web:first", "telegram:release"])
    }

    @Test @MainActor func historyIsScopedToAnEpisodeAndSurvivesProviderIdentityChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        func request(provider: String, episode: Int) -> PlaybackRequest {
            let media = MediaItem(id: provider, providerID: provider, kind: .series, title: "Show", tmdbID: 42)
            let episode = MediaEpisode(id: "\(provider)-\(episode)", providerID: provider, showID: media.id,
                seasonNumber: 1, number: episode, title: nil, overview: nil, posterURL: nil)
            return PlaybackRequest(media: media, episode: episode)
        }
        library.recordPlayedSource("web:one", for: request(provider: "tmdb", episode: 1))
        library.recordPlayedSource("telegram:two", for: request(provider: "tmdb", episode: 2))
        #expect(library.sourceHistory(for: request(provider: "server", episode: 1)) == ["web:one"])
        #expect(library.sourceHistory(for: request(provider: "server", episode: 2)) == ["telegram:two"])
        #expect(library.sourceHistory(for: request(provider: "server", episode: 3)).isEmpty)
    }

    @Test func adaptiveDownloadProgressDoesNotInventByteCounts() {
        let progress = DownloadTransferProgress(received: 0, total: 0, bytesPerSecond: 0, sampledAt: 0, mediaFraction: 0.42)
        #expect(progress.fraction == 0.42)
        #expect(progress.percentage == "42%")
        #expect(!progress.sizeLabel.contains("0 bytes"))
        #expect(progress.speedLabel(now: 10) == "Video download")
    }

    @Test func legacyDownloadsRemainDecodableAndAdaptivePackagesUseNativePlayback() throws {
        let media = TelegramMedia(chatID: 0, messageID: 42, fileID: nil, name: "Offline.movpkg", caption: "", date: .now,
            size: 100, duration: 10, mimeType: "application/vnd.apple.mpegurl", thumbnailFileID: nil, kind: .video, remoteURL: nil)
        let legacy = TelegramSavedDownload(media: media, filename: "video.mp4", savedAt: .now)
        let decoded = try JSONDecoder().decode(TelegramSavedDownload.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.offlineAssetPath == nil)
        #expect(decoded.url.lastPathComponent == "video.mp4")
        var package = legacy
        package.offlineAssetPath = "Library/test.movpkg"
        #expect(package.url.path == NSHomeDirectory() + "/Library/test.movpkg")
        #expect(!package.isCached)
        #expect(TelegramPlayerSession.prefersNative(media))
    }
}


@Suite(.serialized)
struct OfflineSourceDownloadIntegrationTests {
    // Serve a short MP4 and HLS VOD from MYKO_DOWNLOAD_FIXTURE_URL to exercise
    // the real download stack without provider credentials or third-party media.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYKO_DOWNLOAD_FIXTURE_URL"] != nil),
          arguments: ["video.mp4", "video.m3u8"])
    @MainActor func downloadsAndReopensOffline(_ path: String) async throws {
        let base = try #require(ProcessInfo.processInfo.environment["MYKO_DOWNLOAD_FIXTURE_URL"])
        let url = try #require(URL(string: base + "/" + path))
        let id = "offline-integration-" + UUID().uuidString
        let media = MediaItem(id: id, providerID: "test", kind: .movie, title: "Offline integration")
        let request = PlaybackRequest(media: media, episode: nil)
        let source = PlaybackSource(url: url, headers: [:], subtitles: [], preferredPeakBitRate: nil)
        let candidate = PlaybackCandidate(id: id, preference: .init(providerID: "test", serverName: path, audioLanguage: "en"),
            providerName: "Local fixture", subtitleKind: .selectable, resolve: { source })
        let downloads = TelegramDownloads.shared
        downloads.begin(candidate, request: request)
        defer { downloads.cancelWeb(id) }
        for _ in 0..<300 where downloads.webActive.contains(id) {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(!downloads.webActive.contains(id), "Download did not finish before timeout")
        #expect(downloads.webErrors[id] == nil, "\(downloads.webErrors[id] ?? "")")
        let record = try #require(downloads.available(for: request).first { $0.sourceID == id })
        defer { try? downloads.remove(record) }
        #expect(FileManager.default.fileExists(atPath: record.url.path))
        #expect(downloads.local(record.media) == record.url)
        #expect(record.media.size > 0)
        #expect(record.offlineAssetPath != nil || path.hasSuffix(".mp4"))
    }
}

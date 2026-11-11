// Adapted for Velagram iOS, November 2026. See NOTICE and LICENSE.
import Foundation
import Network
import UIKit

enum PlaybackPreloadPolicy: String, CaseIterable, Identifiable, Sendable {
    case off
    case wifiOnly
    case wifiAndCellular

    static let defaultsKey = "player.predictivePreloading"

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .wifiOnly: "Wi-Fi Only"
        case .wifiAndCellular: "Wi-Fi & Cellular"
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: defaultsKey) else { return .wifiOnly }
        return Self(rawValue: rawValue) ?? .wifiOnly
    }
}

enum PlaybackPreloadPriority: Int, Comparable, Sendable {
    case home
    case details

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct PlaybackPreloadConfiguration: Hashable, Sendable {
    let defaultQualityHeight: Int
    let defaultPlaybackRate: Double
    let primarySubtitleLanguage: String
    let secondarySubtitleLanguage: String
    let audioLanguage: String
    let animeAudioLanguage: String
    let animeBackupAudioLanguage: String
    let subtitlesEnabledByDefault: Bool
    let subtitleLoadingMode: SubtitleLoadingMode
    let enabledSubtitleProviderIDs: Set<String>
    let automaticallySelectLatestSubtitleSync: Bool
    let resumePosition: Double
    let playbackRate: Double
    let sourcePreference: PlaybackSourcePreference?
    let savedSubtitleVisibility: Bool?
    let subtitleSelectionBaseKey: String?
    let subtitleSelectionVersionID: UUID?
    let subtitleSyncFingerprint: String

    @MainActor
    static func current(
        for request: PlaybackRequest,
        library: LibraryStore,
        defaults: UserDefaults = .standard
    ) -> Self {
        let defaultRate = defaults.object(forKey: "player.defaultPlaybackRate") as? Double ?? 1
        let subtitleSelection = library.subtitleSelectionPreference(for: request)
        let syncFingerprint = library.subtitleSyncVersions(for: request)
            .map { "\($0.id.uuidString):\($0.offsetTenths)" }
            .joined(separator: "|")
        var subtitleProviders = Set<String>()
        if defaults.object(forKey: "subtitle.provider.subdl.enabled") as? Bool ?? true {
            subtitleProviders.insert("subdl")
        }
        if defaults.object(forKey: "subtitle.provider.wizdom.enabled") as? Bool ?? true {
            subtitleProviders.insert("wizdom")
        }
        if defaults.object(forKey: "subtitle.provider.ktuvit.enabled") as? Bool ?? true {
            subtitleProviders.insert("ktuvit")
        }
        if defaults.object(forKey: "subtitle.provider.externalStreams.enabled") as? Bool ?? true {
            subtitleProviders.insert("external-stream-subtitles")
        }
        return Self(
            defaultQualityHeight: defaults.integer(forKey: "player.defaultQualityHeight"),
            defaultPlaybackRate: defaultRate,
            primarySubtitleLanguage: defaults.string(forKey: "player.subtitleLanguage.primary") ?? "en",
            secondarySubtitleLanguage: defaults.string(forKey: "player.subtitleLanguage.secondary") ?? "",
            audioLanguage: defaults.string(forKey: "player.audioLanguage") ?? "en",
            animeAudioLanguage: defaults.string(forKey: "player.animeAudioLanguage") ?? "en",
            animeBackupAudioLanguage: defaults.string(forKey: "player.animeBackupAudioLanguage") ?? "ja",
            subtitlesEnabledByDefault: defaults.object(forKey: "player.subtitlesEnabledByDefault") as? Bool ?? true,
            subtitleLoadingMode: SubtitleLoadingMode(
                rawValue: defaults.string(forKey: "player.subtitleLoadingMode") ?? ""
            ) ?? .fast,
            enabledSubtitleProviderIDs: subtitleProviders,
            automaticallySelectLatestSubtitleSync: defaults.object(
                forKey: "player.subtitleSync.autoSelectLatest"
            ) as? Bool ?? true,
            resumePosition: library.resumePosition(for: request),
            playbackRate: library.playbackRate(for: request, defaultRate: defaultRate),
            sourcePreference: library.sourcePreference(for: request),
            savedSubtitleVisibility: library.subtitleVisibilityPreference(for: request),
            subtitleSelectionBaseKey: subtitleSelection?.baseSubtitleKey,
            subtitleSelectionVersionID: subtitleSelection?.syncVersionID,
            subtitleSyncFingerprint: syncFingerprint
        )
    }
}

@MainActor
final class PreparedPlayback {
    let request: PlaybackRequest
    let configuration: PlaybackPreloadConfiguration
    let model: PlayerViewModel
    let session: PlayerSession
    let preparedAt: Date

    init(
        request: PlaybackRequest,
        configuration: PlaybackPreloadConfiguration,
        model: PlayerViewModel,
        session: PlayerSession,
        preparedAt: Date = Date()
    ) {
        self.request = request
        self.configuration = configuration
        self.model = model
        self.session = session
        self.preparedAt = preparedAt
    }

    func dispose() {
        model.cancel()
        session.stop()
    }
}

@MainActor
final class PlaybackPreloadCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    weak var environment: AppEnvironment?
    private var task: Task<Void, Never>?
    private var prepared: PreparedPlayback?
    private var request: PlaybackRequest?
    private var configuration: PlaybackPreloadConfiguration?
    private var priority: PlaybackPreloadPriority?
    private var generation = UUID()
    private var isSceneActive = true
    private var isNetworkAvailable = false
    private var isExpensiveNetwork = true
    private let pathMonitor = NWPathMonitor()

    init() {
        let initialPath = pathMonitor.currentPath
        isNetworkAvailable = initialPath.status == .satisfied
        isExpensiveNetwork = initialPath.isExpensive || initialPath.isConstrained
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.applyNetworkPath(path)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Velagram.PlaybackPreload.Network"))
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelWork(reason: "memory-pressure", preservingPrediction: true) }
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if ProcessInfo.processInfo.isLowPowerModeEnabled {
                    self.cancelWork(reason: "low-power-mode", preservingPrediction: true)
                } else {
                    self.restartPredictionIfPossible()
                }
            }
        }
    }

    deinit { pathMonitor.cancel() }

    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active {
            restartPredictionIfPossible()
        } else {
            cancelWork(reason: "scene-inactive", preservingPrediction: true)
        }
    }

    func updatePrediction(
        request newRequest: PlaybackRequest?,
        priority newPriority: PlaybackPreloadPriority,
        configuration newConfiguration: PlaybackPreloadConfiguration?
    ) {
        guard let newRequest, let newConfiguration else {
            if priority == newPriority { cancel(reason: "prediction-cleared") }
            return
        }
        if request == newRequest,
           configuration == newConfiguration,
           priority == newPriority,
           task != nil || prepared != nil {
            return
        }
        if let priority, priority > newPriority, task != nil || prepared != nil { return }

        cancel(reason: "prediction-replaced")
        request = newRequest
        configuration = newConfiguration
        priority = newPriority
        guard isEligible else { return }
        startPrediction(request: newRequest, priority: newPriority, configuration: newConfiguration)
    }

    private func startPrediction(
        request newRequest: PlaybackRequest,
        priority newPriority: PlaybackPreloadPriority,
        configuration newConfiguration: PlaybackPreloadConfiguration
    ) {
        let operation = UUID()
        generation = operation
        state = .preparing(newRequest.contentID)
        PlaybackStartupTrace.mark("preload START content=\(newRequest.contentID)")
        task = Task { [weak self] in
            guard let self, let environment = self.environment else { return }
            let model = PlayerViewModel(request: newRequest)
            await model.load(
                environment: environment,
                enabledSubtitleProviderIDs: newConfiguration.enabledSubtitleProviderIDs,
                audioLanguage: newConfiguration.animeAudioLanguage,
                backupAudioLanguage: newConfiguration.animeBackupAudioLanguage,
                qualityHeight: newConfiguration.defaultQualityHeight
            )
            guard !Task.isCancelled,
                  self.generation == operation,
                  let source = model.source else {
                model.cancel()
                if self.generation == operation { self.finishFailure(for: newRequest) }
                return
            }
            if let expiration = PlayerSession.expirationDate(in: source.url),
               expiration <= Date().addingTimeInterval(90) {
                model.cancel()
                self.finishFailure(for: newRequest)
                return
            }
            let session = PlayerSession()
            let subtitlesEnabled = newConfiguration.savedSubtitleVisibility
                ?? newConfiguration.subtitlesEnabledByDefault
            if newConfiguration.subtitleLoadingMode == .completeBeforePlayback && subtitlesEnabled {
                await model.waitForSubtitleDiscovery()
            }
            await session.load(
                request: newRequest,
                source: source,
                resumeAt: newConfiguration.resumePosition,
                primarySubtitleLanguage: newConfiguration.primarySubtitleLanguage,
                secondarySubtitleLanguage: newConfiguration.secondarySubtitleLanguage,
                audioLanguage: newConfiguration.audioLanguage,
                externalSubtitles: model.allSubtitles,
                subtitleSyncVersions: environment.library.subtitleSyncVersions(for: newRequest),
                automaticallySelectLatestSubtitleSync: newConfiguration.automaticallySelectLatestSubtitleSync,
                subtitlesEnabled: subtitlesEnabled,
                defaultQualityHeight: newConfiguration.defaultQualityHeight,
                defaultPlaybackRate: Float(newConfiguration.playbackRate),
                subtitleLoadingMode: newConfiguration.subtitleLoadingMode,
                subtitleSelectionPreference: environment.library.subtitleSelectionPreference(for: newRequest),
                preparesForActivation: true
            )
            let isPrepared = await session.waitUntilPreparedForPlayback()
            guard isPrepared,
                  !Task.isCancelled,
                  self.generation == operation else {
                model.cancel()
                session.stop()
                if self.generation == operation { self.finishFailure(for: newRequest) }
                return
            }
            self.prepared = PreparedPlayback(
                request: newRequest,
                configuration: newConfiguration,
                model: model,
                session: session
            )
            self.task = nil
            self.state = .ready(newRequest.contentID)
            PlaybackStartupTrace.mark("preload READY content=\(newRequest.contentID)")
        }
    }

    func consumeIfMatching(
        request requested: PlaybackRequest,
        configuration requestedConfiguration: PlaybackPreloadConfiguration
    ) -> PreparedPlayback? {
        guard let prepared,
              prepared.request == requested,
              prepared.configuration == requestedConfiguration,
              isEligible,
              prepared.session.hasFreshPreparedSource else {
            cancel(reason: "explicit-playback-mismatch")
            return nil
        }
        self.prepared = nil
        task?.cancel()
        task = nil
        request = nil
        configuration = nil
        priority = nil
        state = .idle
        PlaybackStartupTrace.mark("preload CONSUMED content=\(requested.contentID)")
        return prepared
    }

    func cancel(reason: String) {
        cancelWork(reason: reason, preservingPrediction: false)
    }

    private func cancelWork(reason: String, preservingPrediction: Bool) {
        guard task != nil || prepared != nil || request != nil else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        prepared?.dispose()
        prepared = nil
        if !preservingPrediction {
            request = nil
            configuration = nil
            priority = nil
        }
        state = .idle
        PlaybackStartupTrace.mark("preload CANCEL reason=\(reason)")
    }

    private var isEligible: Bool {
        guard isSceneActive,
              isNetworkAvailable,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        switch PlaybackPreloadPolicy.current() {
        case .off: return false
        case .wifiOnly: return !isExpensiveNetwork
        case .wifiAndCellular: return true
        }
    }

    private func applyNetworkPath(_ path: NWPath) {
        isNetworkAvailable = path.status == .satisfied
        isExpensiveNetwork = path.isExpensive || path.isConstrained
        if isEligible {
            restartPredictionIfPossible()
        } else {
            cancelWork(reason: "network-policy-change", preservingPrediction: true)
        }
    }

    private func restartPredictionIfPossible() {
        guard isEligible,
              task == nil,
              prepared == nil,
              let request,
              let configuration,
              let priority else { return }
        startPrediction(request: request, priority: priority, configuration: configuration)
    }

    private func finishFailure(for request: PlaybackRequest) {
        guard self.request == request else { return }
        task = nil
        state = .failed(request.contentID)
        PlaybackStartupTrace.mark("preload FAILED content=\(request.contentID)")
    }
}

enum TMDBCatalogMatcher {
    static func resolve(
        _ title: TrendingTitle,
        using provider: any MediaProvider,
        searchPageLimit: Int = 3
    ) async throws -> MediaItem? {
        let queries = [title.originalTitle, title.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reduce(into: [String]()) { values, query in
                guard !query.isEmpty,
                      !values.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) else { return }
                values.append(query)
            }
        for query in queries {
            for page in 1...max(searchPageLimit, 1) {
                try Task.checkCancellation()
                let results = try await provider.search(query: query, page: page)
                guard !results.isEmpty else { break }
                let candidates = results.filter { $0.kind == title.kind }

                if let identifierMatch = candidates.first(where: { $0.tmdbID == title.id }) {
                    return identifierMatch.applyingTMDBMetadata(title)
                }

                // Search payloads sometimes omit TMDB metadata. Verify those candidates
                // against their full detail payload before accepting them.
                for candidate in candidates where candidate.tmdbID == nil {
                    try Task.checkCancellation()
                    do {
                        let details = try await provider.details(for: candidate)
                        if details.kind == title.kind, details.tmdbID == title.id {
                            return details.applyingTMDBMetadata(title)
                        }
                    } catch where error.isCancellation {
                        throw error
                    } catch {
                        continue
                    }
                }
            }
        }
        return nil
    }
}

struct SourceLookupFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

struct ResolvedMediaItem: Identifiable, Hashable, Sendable {
    let media: MediaItem
    let tmdbMetadata: TrendingTitle?

    var id: String { "\(media.providerID):\(media.id)" }
}

@MainActor
final class SourceLookupCoordinator: ObservableObject {
    private enum Outcome: Sendable {
        case found(ResolvedMediaItem)
        case failed(String)
        case cancelled
    }

    private enum ArtworkOutcome: Sendable {
        case found(Data?)
        case cancelled
    }

    @Published private(set) var activeTitles: [String: TrendingTitle] = [:]
    @Published private(set) var activeArtworkKeys: Set<String> = []
    @Published private(set) var failure: SourceLookupFailure?

    private var tasks: [String: Task<Outcome, Never>] = [:]
    private var operationIDs: [String: UUID] = [:]
    private var artworkTasks: [String: Task<ArtworkOutcome, Never>] = [:]
    private var artworkOperationIDs: [String: UUID] = [:]
    private var failureDismissTask: Task<Void, Never>?
    private var playbackTask: Task<PlaybackSource, Error>?
    private var playbackOperationID: UUID?

    var activeKeys: Set<String> { Set(activeTitles.keys) }
    var activeCount: Int { activeTitles.count }

    func resolve(_ title: TrendingTitle, registry: ProviderRegistry) async -> ResolvedMediaItem? {
        ResolvedMediaItem(media: .tmdbCatalogItem(from: title), tmdbMetadata: title)
    }

    func resolvePlaybackSource(
        for request: PlaybackRequest,
        registry: ProviderRegistry
    ) async throws -> PlaybackSource {
        playbackTask?.cancel()
        let operationID = UUID()
        playbackOperationID = operationID
        let task = Task<PlaybackSource, Error> {
            let provider = try await registry.selected()
            let providerRequest = try await Self.providerRequest(for: request, using: provider)
            try Task.checkCancellation()
            return try await provider.playbackSource(for: providerRequest)
        }
        playbackTask = task
        defer {
            if playbackOperationID == operationID {
                playbackTask = nil
                playbackOperationID = nil
            }
        }
        let source = try await task.value
        guard playbackOperationID == operationID else { throw CancellationError() }
        return source
    }

    func resolveArtwork(for item: MediaItem, environment: AppEnvironment) async -> Data? {
        let key = "artwork:\(item.providerID):\(item.id)"
        if let existingTask = artworkTasks[key] {
            if case .found(let artwork) = await existingTask.value { return artwork }
            return nil
        }

        let operationID = UUID()
        let task = Task { () -> ArtworkOutcome in
            do {
                let artwork = try await environment.tmdbHeroArtworkData(for: item)
                try Task.checkCancellation()
                return .found(artwork)
            } catch {
                return .cancelled
            }
        }

        activeArtworkKeys.insert(key)
        artworkOperationIDs[key] = operationID
        artworkTasks[key] = task

        let outcome = await task.value
        guard artworkOperationIDs[key] == operationID else { return nil }
        activeArtworkKeys.remove(key)
        artworkOperationIDs[key] = nil
        artworkTasks[key] = nil

        if case .found(let artwork) = outcome { return artwork }
        return nil
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        artworkTasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        artworkTasks.removeAll()
        operationIDs.removeAll()
        artworkOperationIDs.removeAll()
        activeTitles.removeAll()
        activeArtworkKeys.removeAll()
        playbackTask?.cancel()
        playbackTask = nil
        playbackOperationID = nil
    }

    nonisolated static func providerRequest(
        for request: PlaybackRequest,
        using provider: any MediaProvider
    ) async throws -> PlaybackRequest {
        let media = request.media
        let title = TrendingTitle(
            id: media.tmdbID ?? -1,
            kind: media.kind,
            title: media.title,
            originalTitle: media.originalTitle,
            overview: media.overview ?? "",
            releaseDate: media.releaseDate,
            rating: media.rating,
            genreNames: media.genres.map(\.name),
            posterURL: media.posterURL,
            backdropURL: media.backdropURL
        )
        guard title.id >= 0,
              let providerSummary = try await TMDBCatalogMatcher.resolve(title, using: provider) else {
            throw AppError.noStream
        }
        try Task.checkCancellation()
        guard media.kind == .series, let episode = request.episode else {
            return PlaybackRequest(media: providerSummary, episode: nil)
        }

        let providerShow = try await provider.details(for: providerSummary)
        guard let providerSeason = providerShow.seasons.first(where: {
            $0.number == episode.seasonNumber
        }) else { throw AppError.noStream }
        let providerEpisodes = try await provider.episodes(for: providerSeason, show: providerShow)
        try Task.checkCancellation()
        guard let providerEpisode = providerEpisodes.first(where: {
            $0.number == episode.number && $0.seasonNumber == episode.seasonNumber
        }) else { throw AppError.noStream }
        return PlaybackRequest(media: providerShow, episode: providerEpisode)
    }

    private func showFailure(_ message: String) {
        let value = SourceLookupFailure(title: "Something went wrong", message: message)
        failure = value
        failureDismissTask?.cancel()
        failureDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard self?.failure?.id == value.id else { return }
            self?.failure = nil
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var shelves: [MediaShelf] = []
    @Published private(set) var trendingTitles: [TrendingTitle] = []
    @Published private(set) var tmdbShelves: [TMDBCollection: [TrendingTitle]] = [:]
    @Published private(set) var carouselAssets = TMDBCarouselAssets()
    @Published private(set) var isLoading = false
    @Published private(set) var isTrendingLoading = false
    @Published var errorMessage: String?
    @Published var trendingMessage: String?

    func loadTrending(environment: AppEnvironment, force: Bool = false) async {
        guard force || trendingTitles.isEmpty else { return }
        isTrendingLoading = true
        defer { isTrendingLoading = false }
        do {
            async let hero = environment.trendingTitles()
            await withTaskGroup(of: (TMDBCollection, [TrendingTitle]?).self) { group in
                for collection in TMDBCollection.homeSections {
                    group.addTask {
                        let page = try? await environment.tmdbTitles(
                            in: collection,
                            forceRefresh: force
                        )
                        return (collection, page?.titles)
                    }
                }
                for await (collection, titles) in group {
                    if let titles { tmdbShelves[collection] = titles }
                }
            }
            let heroTitles = try await hero
            trendingTitles = heroTitles
            trendingMessage = trendingTitles.isEmpty ? "TMDB did not return any trending titles." : nil
            carouselAssets = await environment.preloadCarouselAssets(for: heroTitles)
        }
        catch where error.isCancellation { }
        catch { trendingMessage = error.localizedDescription }
    }

}

@MainActor
final class TMDBCollectionsViewModel: ObservableObject {
    let collections: [TMDBCollection]
    @Published private(set) var titles: [TMDBCollection: [TrendingTitle]] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    init(collections: [TMDBCollection]) {
        self.collections = collections
    }

    func load(environment: AppEnvironment, force: Bool = false) async {
        guard !isLoading, force || titles.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        if force { titles = [:] }
        await withTaskGroup(of: (TMDBCollection, [TrendingTitle]?, String?).self) { group in
            for collection in collections {
                group.addTask {
                    do {
                        let page = try await environment.tmdbTitles(
                            in: collection,
                            forceRefresh: force
                        )
                        return (collection, page.titles, nil)
                    } catch where error.isCancellation {
                        return (collection, nil, nil)
                    } catch {
                        return (collection, nil, error.localizedDescription)
                    }
                }
            }
            for await (collection, loadedTitles, message) in group {
                if let loadedTitles { titles[collection] = loadedTitles }
                if errorMessage == nil, let message { errorMessage = message }
            }
        }
    }
}

@MainActor
final class TMDBCollectionGridViewModel: ObservableObject {
    @Published private(set) var titles: [TrendingTitle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = true
    @Published var errorMessage: String?
    private var page = 0

    func loadNext(collection: TMDBCollection, environment: AppEnvironment) async {
        guard !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await environment.tmdbTitles(in: collection, page: page + 1)
            titles.append(contentsOf: result.titles.filter { candidate in
                !titles.contains { $0.id == candidate.id && $0.kind == candidate.kind }
            })
            page = result.page
            canLoadMore = result.page < result.totalPages && !result.titles.isEmpty
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
final class CatalogViewModel: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = true
    @Published var errorMessage: String?
    private var page = 0
    let kind: MediaKind

    init(kind: MediaKind) { self.kind = kind }

    func loadNext(registry: ProviderRegistry) async {
        guard !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = page + 1
            let provider = try await registry.selected()
            let result = try await (kind == .movie ? provider.movies(page: next) : provider.series(page: next))
            items.append(contentsOf: result.filter { candidate in !items.contains(where: { $0.id == candidate.id }) })
            page = next
            canLoadMore = !result.isEmpty
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [MediaItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var searchGeneration = 0

    func search(environment: AppEnvironment) {
        task?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = false
        errorMessage = nil
        guard !value.isEmpty else {
            results = []
            task = nil
            return
        }
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self, searchGeneration == generation else { return }
            isLoading = true
            defer {
                if searchGeneration == generation {
                    isLoading = false
                    task = nil
                }
            }
            do {
                let titles = try await environment.tmdbSearch(query: value).titles
                guard searchGeneration == generation else { return }
                results = titles.map {
                    MediaItem.tmdbCatalogItem(from: $0)
                }
            }
            catch where error.isCancellation { }
            catch {
                guard searchGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
final class DetailsViewModel: ObservableObject {
    @Published private(set) var item: MediaItem
    @Published private(set) var episodes: [String: [MediaEpisode]] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private let tmdbMetadataSnapshot: TrendingTitle?

    init(item: MediaItem, tmdbMetadataSnapshot: TrendingTitle? = nil) {
        self.item = item
        self.tmdbMetadataSnapshot = tmdbMetadataSnapshot
    }

    var orderedSeasons: [MediaSeason] {
        item.seasons.sorted {
            if ($0.number == 0) != ($1.number == 0) { return $1.number == 0 }
            return $0.number < $1.number
        }
    }

    func load(environment: AppEnvironment, preferredSeasonNumber: Int? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            item = try await environment.tmdbDetails(for: item)
            if let season = orderedSeasons.first {
                await loadEpisodes(season, environment: environment)
            }
            if let preferredSeasonNumber,
               let season = item.seasons.first(where: { $0.number == preferredSeasonNumber }) {
                await loadEpisodes(season, environment: environment)
            }
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }

    func loadEpisodes(_ season: MediaSeason, environment: AppEnvironment) async {
        guard episodes[season.id] == nil else { return }
        do {
            episodes[season.id] = try await environment.tmdbEpisodes(for: season, show: item)
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    private struct PlaybackSnapshot {
        let request: PlaybackRequest
        let source: PlaybackSource?
        let streams: [PlayableStream]
        let selectedSourceID: String?
        let rememberedSource: PlaybackSourcePreference?
        let thirdPartySubtitles: [SubtitleSource]
        let subtitleRevision: Int
        let isSubtitleDiscoveryComplete: Bool
        let sourceRevision: Int
        let errorMessage: String?
    }

    @Published private(set) var source: PlaybackSource?
    @Published private(set) var streams: [PlayableStream] = []
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var rememberedSource: PlaybackSourcePreference?
    @Published private(set) var thirdPartySubtitles: [SubtitleSource] = []
    @Published private(set) var subtitleRevision = 0
    @Published private(set) var isSubtitleDiscoveryComplete = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSwitching = false
    @Published private(set) var isSearching = false
    @Published private(set) var sourceRevision = 0
    @Published var errorMessage: String?
    @Published private(set) var request: PlaybackRequest
    private let discovery = PlaybackDiscovery()
    private var contextTask: Task<PlaybackLookupContext, Never>?
    private var failedSources: Set<String> = []
    private var refreshedSources: Set<String> = []
    private var refreshedURLs: Set<URL> = []
    private var operation = UUID()
    private var policy = StreamSelectionPolicy()
    private var sourceSelectionGeneration = UUID()
    private var subtitleDiscoveryTask: Task<Void, Never>?
    private var subtitleDiscoveryWorkerTask: Task<Void, Never>?
    private var subtitleDiscoveryGeneration = UUID()
    private var pendingPlaybackSnapshot: PlaybackSnapshot?

    var allSubtitles: [SubtitleSource] {
        var seenResources: Set<String> = []
        return ((source?.subtitles ?? []) + thirdPartySubtitles).filter { subtitle in
            seenResources.insert(subtitle.syncKey).inserted
        }
    }

    private var initialStream: PlayableStream?

    init(request: PlaybackRequest, initialStream: PlayableStream? = nil) { self.request = request; self.initialStream = initialStream }

    func load(environment: AppEnvironment, enabledSubtitleProviderIDs: Set<String>,
              audioLanguage: String, backupAudioLanguage: String = "", qualityHeight: Int, force: Bool = false) async {
        guard (source == nil || force), !isLoading else { return }
        let token = UUID()
        operation = token
        isLoading = true
        errorMessage = nil
        failedSources = []
        refreshedSources = []
        refreshedURLs = []
        rememberedSource = environment.library.sourcePreference(for: request)
        policy = StreamSelectionPolicy(preference: rememberedSource, audioLanguage: audioLanguage,
            backupAudioLanguage: backupAudioLanguage, qualityHeight: qualityHeight)
        defer { if operation == token { isLoading = false } }
        let originalPlaybackRequest = request
        discovery.onUpdate = { [weak self] streams in
            guard self?.operation == token else { return }
            self?.streams = streams
        }
        discovery.onSearchingChanged = { [weak self] isSearching in
            guard self?.operation == token else { return }
            self?.isSearching = isSearching
        }
        do {
            let playbackRequest = await environment.canonicalPlaybackRequest(
                for: originalPlaybackRequest
            )

            guard operation == token,
                  !Task.isCancelled else {
                return
            }
            startSubtitleDiscovery(
                for: playbackRequest,
                environment: environment,
                enabledProviderIDs: enabledSubtitleProviderIDs,
                operationToken: token
            )
            if let selected = initialStream {
                initialStream = nil
                source = selected.source; streams = [selected]; selectedSourceID = selected.id
                sourceRevision &+= 1
                return
            }
            let enrichment = Task { await environment.playbackContext(for: playbackRequest) }
            contextTask = enrichment
            let registered = await environment.registry.playbackProviders()
            let providers = registered.map { provider -> any PlaybackProvider in
                if provider is StreamingCommunityPlaybackProvider { return provider }
                return EnrichedPlaybackProvider(provider: provider, context: enrichment)
            }
            try Task.checkCancellation()
            let selected = try await discovery.start(context: PlaybackLookupContext(request: playbackRequest),
                providers: providers, policy: policy)
            guard operation == token, !Task.isCancelled else { return }
            source = selected.source
            selectedSourceID = selected.id
            sourceRevision &+= 1
            PlaybackStartupTrace.mark(
                "SUBTITLE PERF video source PUBLISHED content=\(playbackRequest.contentID)"
            )
        } catch where error.isCancellation { }
        catch { if operation == token { errorMessage = error.localizedDescription } }
    }

    @discardableResult
    func play(_ request: PlaybackRequest, environment: AppEnvironment,
              enabledSubtitleProviderIDs: Set<String>, audioLanguage: String,
              backupAudioLanguage: String = "", qualityHeight: Int) async -> Bool {
        guard pendingPlaybackSnapshot == nil else { return false }
        pendingPlaybackSnapshot = PlaybackSnapshot(
            request: self.request,
            source: source,
            streams: streams,
            selectedSourceID: selectedSourceID,
            rememberedSource: rememberedSource,
            thirdPartySubtitles: thirdPartySubtitles,
            subtitleRevision: subtitleRevision,
            isSubtitleDiscoveryComplete: isSubtitleDiscoveryComplete,
            sourceRevision: sourceRevision,
            errorMessage: errorMessage
        )
        cancel()
        self.request = request
        source = nil
        streams = []
        selectedSourceID = nil
        thirdPartySubtitles = []
        subtitleRevision &+= 1
        await load(environment: environment, enabledSubtitleProviderIDs: enabledSubtitleProviderIDs,
                   audioLanguage: audioLanguage, backupAudioLanguage: backupAudioLanguage, qualityHeight: qualityHeight)
        return !Task.isCancelled && source != nil
    }

    func commitPendingPlayback() {
        pendingPlaybackSnapshot = nil
    }

    func cancelPendingPlayback() {
        guard let snapshot = pendingPlaybackSnapshot else { return }
        let publishedPendingSource = source != nil
        cancel()
        pendingPlaybackSnapshot = nil
        request = snapshot.request
        source = snapshot.source
        streams = snapshot.streams
        selectedSourceID = snapshot.selectedSourceID
        rememberedSource = snapshot.rememberedSource
        thirdPartySubtitles = snapshot.thirdPartySubtitles
        subtitleRevision = snapshot.subtitleRevision
        isSubtitleDiscoveryComplete = snapshot.isSubtitleDiscoveryComplete
        errorMessage = snapshot.errorMessage
        if publishedPendingSource {
            sourceRevision = snapshot.sourceRevision
        }
    }

    func selectSource(
        _ id: String?,
        quality: StreamQuality?,
        library: LibraryStore,
        apply: (PlayableStream, StreamQuality?) async -> Bool
    ) async -> Bool {
        let selectionGeneration = UUID()
        sourceSelectionGeneration = selectionGeneration

        if id == nil {
            library.updateSourcePreference(nil, for: request)
            rememberedSource = nil
            policy.preference = nil
        }

        guard let target =
            id.flatMap({ id in
                streams.first { $0.id == id }
            })
            ?? policy.best(in: streams)
        else {
            return false
        }

        let token = operation

        isSwitching = true

        defer {
            if operation == token,
               sourceSelectionGeneration == selectionGeneration {
                isSwitching = false
            }
        }

        do {
            let fresh = try await PlaybackDiscovery.prepare(
                target.candidate
            )

            guard operation == token,
                  sourceSelectionGeneration == selectionGeneration,
                  !Task.isCancelled else {
                return false
            }

            let applied = await apply(
                fresh,
                quality
            )

            guard operation == token,
                  sourceSelectionGeneration == selectionGeneration,
                  !Task.isCancelled else {
                return false
            }

            guard applied else {
                throw AppError.noStream
            }

            source = fresh.source
            selectedSourceID = fresh.id

            failedSources.remove(fresh.id)
            refreshedSources.remove(fresh.id)

            if id != nil {
                rememberedSource =
                    fresh.candidate.preference

                policy.preference =
                    rememberedSource

                library.updateSourcePreference(
                    rememberedSource,
                    for: request
                )
            }

            return true
        } catch where error.isCancellation {
            return false
        } catch {
            guard operation == token,
                  sourceSelectionGeneration == selectionGeneration else {
                return false
            }

            errorMessage =
                "This source could not be opened. Playback returned to your previous source."

            return false
        }
    }

    func supersedeSourceSelection() {
        sourceSelectionGeneration = UUID()
        isSwitching = false
    }

    func recover(apply: (PlayableStream) async -> Bool) async -> Bool {
        guard !isSwitching, let selectedSourceID else { return false }
        isSwitching = true
        let token = operation
        defer { if operation == token { isSwitching = false } }
        let expirationRefresh = source.flatMap { PlayerSession.expirationDate(in: $0.url) }
            .map { $0 <= Date().addingTimeInterval(30) } ?? false
        let canRefresh = expirationRefresh
            ? source.map { refreshedURLs.insert($0.url).inserted } ?? false
            : refreshedSources.insert(selectedSourceID).inserted
        let recoveryOrder = SourceRecoveryOrder.ordered(
            selectedSourceID: selectedSourceID,
            streams: streams,
            policy: policy,
            excluding: failedSources
        )
        if canRefresh,
           let current = recoveryOrder.first(where: { $0.id == selectedSourceID }),
           let fresh = try? await PlaybackDiscovery.prepare(current.candidate), operation == token,
           await apply(fresh) { source = fresh.source; return true }
        failedSources.insert(selectedSourceID)
        // Discovery may still be finding alternatives when the first stream fails.
        while operation == token, !Task.isCancelled {
            if let next = policy.best(in: streams.filter { !failedSources.contains($0.id) }) {
                failedSources.insert(next.id)
                if let fresh = try? await PlaybackDiscovery.prepare(next.candidate), operation == token,
                   await apply(fresh) {
                    source = fresh.source
                    self.selectedSourceID = fresh.id
                    return true
                }
            } else if discovery.isSearching {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            } else { return false }
        }
        return false
    }

    func rememberCurrentSource(library: LibraryStore) {
        guard let stream = streams.first(where: { $0.id == selectedSourceID }) else { return }
        rememberedSource = stream.candidate.preference
        policy.preference = rememberedSource
        library.updateSourcePreference(rememberedSource, for: request)
    }

    func resetRecovery() { failedSources = []; refreshedSources = []; refreshedURLs = [] }

    func waitForSubtitleDiscovery() async {
        await subtitleDiscoveryTask?.value
    }

    private func startSubtitleDiscovery(
        for playbackRequest: PlaybackRequest,
        environment: AppEnvironment,
        enabledProviderIDs: Set<String>,
        operationToken: UUID
    ) {
        subtitleDiscoveryTask?.cancel()
        subtitleDiscoveryWorkerTask?.cancel()
        thirdPartySubtitles = []
        isSubtitleDiscoveryComplete = false
        subtitleRevision &+= 1
        let generation = UUID()
        subtitleDiscoveryGeneration = generation

        guard let lookup = playbackRequest.subtitleLookupRequest else {
            isSubtitleDiscoveryComplete = true
            return
        }

        let worker = Task { [weak self] in
            let events = await environment.subtitleRegistry.progressiveResults(
                for: lookup,
                fallbackTMDbID: playbackRequest.media.tmdbID,
                enabledProviderIDs: enabledProviderIDs
            )
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.applySubtitleProviderResult(
                    event,
                    generation: generation,
                    operationToken: operationToken
                )
            }
        }
        subtitleDiscoveryWorkerTask = worker

        subtitleDiscoveryTask = Task { [weak self] in
            let completion = AsyncStream<Bool> { continuation in
                let completed = Task {
                    await worker.value
                    continuation.yield(true)
                    continuation.finish()
                }
                let timeout = Task {
                    do {
                        try await Task.sleep(for: .seconds(15))
                        continuation.yield(false)
                        continuation.finish()
                    } catch { }
                }
                continuation.onTermination = { _ in
                    completed.cancel()
                    timeout.cancel()
                }
            }
            var discoveryFinished = false
            for await finished in completion {
                discoveryFinished = finished
                break
            }
            if !discoveryFinished { worker.cancel() }
            worker.cancel()
            guard let self,
                  self.operation == operationToken,
                  self.subtitleDiscoveryGeneration == generation else { return }
            self.subtitleDiscoveryWorkerTask = nil
            self.isSubtitleDiscoveryComplete = true
            PlaybackStartupTrace.mark(
                "SUBTITLE PERF background discovery DONE tracks=\(self.thirdPartySubtitles.count)"
            )
        }
    }

    private func applySubtitleProviderResult(
        _ event: SubtitleProviderResult,
        generation: UUID,
        operationToken: UUID
    ) {
        guard operation == operationToken,
              subtitleDiscoveryGeneration == generation else { return }
        var seen = Set(thirdPartySubtitles.map(\.syncKey))
        let additions = event.subtitles.filter { seen.insert($0.syncKey).inserted }
        guard !additions.isEmpty else { return }
        thirdPartySubtitles.append(contentsOf: additions)
        thirdPartySubtitles.sort {
            if $0.providerName != $1.providerName { return $0.providerName < $1.providerName }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        subtitleRevision &+= 1
    }

    func cancel() {
        operation = UUID()
        discovery.cancel()
        contextTask?.cancel()
        contextTask = nil
        subtitleDiscoveryTask?.cancel()
        subtitleDiscoveryTask = nil
        subtitleDiscoveryWorkerTask?.cancel()
        subtitleDiscoveryWorkerTask = nil
        subtitleDiscoveryGeneration = UUID()
        isLoading = false
        isSwitching = false
        isSearching = false
    }
}

enum SourceRecoveryOrder {
    static func ordered(
        selectedSourceID: String,
        streams: [PlayableStream],
        policy: StreamSelectionPolicy,
        excluding failed: Set<String> = []
    ) -> [PlayableStream] {
        var remaining = streams.filter { !failed.contains($0.id) }
        var result: [PlayableStream] = []
        if let index = remaining.firstIndex(where: { $0.id == selectedSourceID }) {
            result.append(remaining.remove(at: index))
        }
        while let next = policy.best(in: remaining) {
            result.append(next)
            remaining.removeAll { $0.id == next.id }
        }
        return result
    }
}

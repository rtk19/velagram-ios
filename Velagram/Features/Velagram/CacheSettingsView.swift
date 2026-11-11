import SwiftUI

struct CacheSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(VideoCacheRetention.defaultsKey) private var retention = 7
    @AppStorage(CacheManager.sizeLimitKey) private var sizeLimitGB = 0
    @AppStorage("cache.lastCleaned") private var lastCleaned: Double = 0
    @State private var telegram = TelegramStore.shared
    @State private var overview = CacheOverview()
    @State private var loading = false
    @State private var cleaning = false
    @State private var confirmation: CacheCleanup?
    @State private var notice: String?
    @State private var failure: String?
    private var busy: Bool { loading || cleaning }
    private var transport: (any TelegramTransport)? { telegram.ready ? telegram.transport : nil }
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(bytes(overview.total)).font(.system(.largeTitle, design: .rounded).bold()).monospacedDigit()
                        .accessibilityIdentifier("cache.total")
                    Text("Reclaimable cache").font(.subheadline).foregroundStyle(.secondary)
                    if overview.total > 0 {
                        GeometryReader { geometry in
                            HStack(spacing: 2) {
                                segment(overview.video, .blue, geometry.size.width)
                                segment(overview.images, .purple, geometry.size.width)
                                segment(overview.subtitles, .orange, geometry.size.width)
                                segment(overview.other, .gray, geometry.size.width)
                            }.clipShape(Capsule())
                        }.frame(height: 8).accessibilityHidden(true)
                    }
                }.padding(.vertical, 8)
                usage("Video & Telegram files", symbol: "film", value: overview.video, tint: .blue)
                usage("Artwork & thumbnails", symbol: "photo", value: overview.images, tint: .purple)
                usage("Subtitles", symbol: "captions.bubble", value: overview.subtitles, tint: .orange)
                usage("Other cache & logs", symbol: "internaldrive", value: overview.other, tint: .gray)
                LabeledContent("Device free space", value: bytes(overview.available))
                if lastCleaned > 0 { LabeledContent("Last cleaned") { Text(Date(timeIntervalSince1970: lastCleaned), style: .relative).foregroundStyle(.secondary) } }
                Button { Task { await refresh() } } label: {
                    HStack { Label("Refresh usage", systemImage: "arrow.clockwise"); Spacer(); if loading { ProgressView() } }
                }.disabled(busy).accessibilityIdentifier("cache.refresh")
            } header: { Text("Storage overview") } footer: {
                Text(overview.telegramAvailable ? "Shows disk space used by downloaded cache, including partial videos. Video documents are included with videos." : "Telegram cache is grouped under Video & Telegram files until detailed usage is available.")
            }.listRowBackground(VelagramTheme.surface)
            Section {
                Picker("Keep unused video cache", selection: $retention) {
                    ForEach(VideoCacheRetention.allCases) { Text($0.title).tag($0.rawValue) }
                }.accessibilityIdentifier("cache.retention")
                Picker("Maximum video cache", selection: $sizeLimitGB) {
                    Text("Unlimited").tag(0)
                    ForEach([1, 2, 5, 10, 20], id: \.self) { Text("\($0) GB").tag($0) }
                }.accessibilityIdentifier("cache.limit")
                Text("Unused videos are removed when Velagram opens or returns to the foreground. Cleanup waits while you play, cast, or download. A size limit can remove older files sooner.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Automatic video cleanup") } footer: { Text("Saved offline downloads are excluded. Videos removed from cache can be streamed again.") }
                .disabled(cleaning).listRowBackground(VelagramTheme.surface)
            Section {
                cleanupButton(.videos, symbol: "film")
                cleanupButton(.images, symbol: "photo")
                cleanupButton(.subtitles, symbol: "captions.bubble")
                cleanupButton(.all, symbol: "trash")
            } header: { Text("Clear cache") } footer: {
                Text("Clears temporary files only. Your Telegram login, watch history, favorites, playlists, subtitle sync settings, and saved offline downloads are kept.")
            }.disabled(busy).listRowBackground(VelagramTheme.surface)
            Section {
                LabeledContent("Saved offline videos", value: bytes(overview.savedDownloads))
                NavigationLink("Manage offline downloads") { TelegramDownloadsView(store: telegram) }
            } header: { Text("Offline downloads") } footer: { Text("Manage saved videos separately; Clear all cache does not delete them.") }
                .listRowBackground(VelagramTheme.surface)
            if cleaning { Section { HStack { ProgressView(); Text("Clearing cache…") } } }
            if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
        }
        .scrollContentBackground(.hidden).background(environment.theme.backgroundGradient)
        .refreshable { await refresh() }
        .navigationTitle("Cache & Storage").navigationBarTitleDisplayMode(.inline)
        .task { environment.playbackPreloader.cancel(reason: "Cache management"); await telegram.start(); await refresh() }
        .onChange(of: telegram.ready) { _, _ in Task { await refresh() } }
        .onChange(of: retention) { _, _ in applyPolicy() }
        .onChange(of: sizeLimitGB) { _, _ in applyPolicy() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
        .confirmationDialog(confirmation?.title ?? "Clear cache", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let action = confirmation {
                Button(action.title, role: .destructive) { confirmation = nil; Task { await clear(action) } }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { Text("Cached files will download again when needed. Your account and saved offline videos will stay on this device.") }
        .alert("Cache management", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func usage(_ title: String, symbol: String, value: Int64, tint: Color) -> some View {
        HStack { Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }; Spacer(); Text(bytes(value)).foregroundStyle(.secondary).monospacedDigit() }
    }
    private func segment(_ value: Int64, _ color: Color, _ width: CGFloat) -> some View {
        color.frame(width: max(0, (width - 6) * CGFloat(value) / CGFloat(max(1, overview.total))))
    }
    private func cleanupButton(_ action: CacheCleanup, symbol: String) -> some View {
        Button(role: action == .all ? .destructive : nil) { confirmation = action } label: { Label(action.title, systemImage: symbol) }
            .accessibilityIdentifier("cache.clear.\(action.rawValue)")
    }
    private func refresh() async {
        guard !busy else { return }; loading = true; defer { loading = false }
        overview = await CacheManager.shared.overview(transport: transport)
    }
    private func clear(_ action: CacheCleanup) async {
        cleaning = true; notice = nil
        environment.playbackPreloader.cancel(reason: "Cache cleanup")
        do {
            try await CacheManager.shared.clear(action, transport: transport)
            if action == .images || action == .all { await environment.clearArtworkCache() }
            if action == .images || action == .all { telegram.thumbnails = [:] }
            notice = "Cache cleared. Cached content may download again as you browse."
        } catch { failure = error.localizedDescription }
        cleaning = false; await refresh()
    }
    private func applyPolicy() {
        notice = "Video cache policy saved. It will be applied at the next idle foreground check."
        guard let transport else { return }
        Task { await CacheManager.shared.maintain(transport: transport, force: true); await refresh() }
    }
}

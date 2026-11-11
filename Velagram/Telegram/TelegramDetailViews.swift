import SwiftUI

struct TelegramMediaActions: View {
    let media: TelegramMedia
    let store: TelegramStore
    var body: some View {
        Menu("Category") {
            ForEach(TelegramCategory.allCases) { category in
                Button(category == .all ? "Automatic" : category.rawValue) { store.mark(media, as: category) }
            }
        }
        if media.fileID != nil {
            Button("Download for offline use", systemImage: "arrow.down.circle") { TelegramDownloads.shared.begin(media, store: store) }
        }
    }
}

struct TelegramMediaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let media: TelegramMedia
    let store: TelegramStore
    var queue: [TelegramMedia] = []
    @State private var downloads = TelegramDownloads.shared
    @State private var playing = false
    @State private var notice: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TelegramThumbnail(fileID: media.thumbnailFileID, store: store).frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 18))
                Text(media.title).font(.title.bold())
                Text(media.name).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    if media.size > 0 { Label(media.formattedSize, systemImage: "internaldrive") }
                    if media.duration > 0 { Text(Duration.seconds(media.duration).formatted(.time(pattern: .minuteSecond))) }
                    Text(store.category(media).rawValue)
                }.font(.caption).foregroundStyle(.secondary)
                if media.isVideo || media.kind == .audio || media.kind == .link {
                    Button { playing = true } label: { Label(VelagramStore.shared.progress["telegram:\(media.id)"] == nil ? "Play" : "Resume", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(10) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("telegram.play")
                }
                if let url = downloads.local(media) {
                    Label("Available offline", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    ShareLink(item: url) { Label("Share downloaded file", systemImage: "square.and.arrow.up") }
                    if ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
                        Button("Import playlist into Live TV") {
                            do { try VelagramStore.shared.importText(String(contentsOf: url, encoding: .utf8)); notice = "Playlist imported into Live TV." }
                            catch { notice = error.localizedDescription }
                        }
                    }
                } else if let id = media.fileID {
                    if downloads.active[id] != nil {
                        let file = store.files[id]
                        ProgressView(value: file.map { $0.size > 0 ? Double($0.downloadedSize) / Double($0.size) : 0 } ?? 0)
                        Button("Cancel download", role: .cancel) { downloads.cancel(id, store: store) }
                    } else {
                        Button("Download for offline use", systemImage: "arrow.down.circle") { downloads.begin(media, store: store) }
                    }
                    if let error = downloads.errors[id] { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                Menu("Organize as \(store.category(media).rawValue)") {
                    ForEach(TelegramCategory.allCases) { category in Button(category == .all ? "Automatic" : category.rawValue) { store.mark(media, as: category) } }
                }
                if !media.caption.isEmpty { Text(media.caption).textSelection(.enabled) }
                if let chat = store.chats[media.chatID] { Label(chat.title, systemImage: "bubble.left.and.bubble.right").font(.caption).foregroundStyle(.secondary) }
                Text(media.date.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                if let notice { Text(notice).font(.caption) }
            }.padding(20)
        }
        .navigationTitle("Telegram file").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .fullScreenCover(isPresented: $playing) { TelegramPlayerView(media: media, store: store, queue: queue) }
    }
}

struct TelegramDownloadsView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TelegramStore
    @State private var downloads = TelegramDownloads.shared
    @State private var selection: TelegramMedia?
    @State private var failure: String?
    var body: some View {
        List {
            if !downloads.active.isEmpty {
                Section("Downloading") {
                    ForEach(downloads.active.values.sorted { $0.id < $1.id }) { media in
                        VStack(alignment: .leading) {
                            Text(media.name).font(.headline)
                            if let id = media.fileID {
                                if let file = store.files[id], file.size > 0 { ProgressView(value: Double(file.downloadedSize) / Double(file.size)) }
                                Button("Cancel") { downloads.cancel(id, store: store) }
                            }
                        }
                    }
                }
            }
            Section("Available offline") {
                if downloads.saved.isEmpty { ContentUnavailableView("Take your files with you", systemImage: "arrow.down.circle", description: Text("Download files from any Telegram media page. Saved files remain available without an internet connection.")) }
                ForEach(downloads.saved) { download in
                    Button { selection = download.media } label: { TelegramMediaRow(media: download.media, store: store) }.buttonStyle(.plain)
                        .swipeActions { Button("Remove", role: .destructive) { do { try downloads.remove(download) } catch { failure = error.localizedDescription } } }
                }
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
        }.navigationTitle("Telegram downloads")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $selection) { media in NavigationStack { TelegramMediaDetailView(media: media, store: store) } }
    }
}

struct TelegramOpenChatView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TelegramStore
    @State private var address = ""
    @State private var chat: TelegramChat?
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        Form {
            Section {
                TextField("@username or https://t.me/…", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Open group or channel") { run(join: false) }.disabled(address.isEmpty || busy)
                if address.contains("t.me/+") || address.contains("joinchat/") {
                    Button("Join group using this invitation") { run(join: true) }.disabled(busy)
                    Text("Joining changes your Telegram group membership. Telegram may require administrator approval.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if busy { ProgressView() }
            if let failure { Text(failure).foregroundStyle(.orange) }
            if let chat { NavigationLink { TelegramLibraryView(store: store, chatID: chat.id).navigationTitle(chat.title) } label: { TelegramChatRow(chat: chat, store: store) } }
        }.navigationTitle("Open Telegram group")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private func run(join: Bool) {
        Task {
            busy = true; failure = nil; defer { busy = false }
            do { chat = try await (join ? store.join(address) : store.openPublicChat(address)) }
            catch { failure = error.localizedDescription }
        }
    }
}

struct TelegramAccountView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TelegramStore
    @State private var name = ""
    @State private var confirmingLogout = false
    var body: some View {
        Form {
            Section("Account") {
                if !name.isEmpty { LabeledContent("Signed in as", value: name) }
                LabeledContent("Connection", value: store.status)
                Text("Telegram login data is encrypted on this device and excluded from exported Velagram backups. Saved downloads and your organization preferences are included.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Sign out of Telegram", role: .destructive) { confirmingLogout = true }
            }
        }.navigationTitle("Telegram account")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of Telegram on this device?", isPresented: $confirmingLogout, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await store.logOut(); dismiss() } }
            }
            .task {
                if let user = try? await store.transport.call("getMe") { name = [user["first_name"].string, user["last_name"].string].compactMap { $0 }.joined(separator: " ") }
            }
    }
}

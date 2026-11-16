import SwiftUI

struct MediaServersView: View {
    @State private var store = VelagramStore.shared
    @State private var adding = false
    var body: some View {
        List {
            if store.servers.isEmpty {
                ContentUnavailableView("Your own cinema", systemImage: "externaldrive.connected.to.line.below", description: Text("Connect your Jellyfin or Emby server to browse and play your personal collection."))
            }
            ForEach(store.servers) { server in
                NavigationLink { ServerBrowserView(server: server) } label: { Label(server.name, systemImage: "server.rack") }
            }.onDelete { offsets in
                for index in offsets { ServerTokenStore.delete(store.servers[index].id) }
                store.servers.remove(atOffsets: offsets); store.persist()
            }
            Button("Connect a server", systemImage: "plus") { adding = true }
        }.navigationTitle("Media servers")
            .sheet(isPresented: $adding) { NavigationStack { AddServerView() } }
    }
}

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind = MediaServer.Kind.jellyfin
    @State private var address = ""
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var quickConnect = false
    var body: some View {
        Form {
            Picker("Server type", selection: $kind) { ForEach(MediaServer.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            TextField("Display name", text: $name)
            TextField("https://your-server:8096", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            if kind == .jellyfin {
                Button("Use Quick Connect", systemImage: "bolt.fill") { quickConnect = true }
                    .disabled(busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Password", text: $password)
            Button {
                Task {
                    busy = true; defer { busy = false }
                    do {
                        let (server, token) = try await MediaServerClient.signIn(url: VelagramHTTP.url(address), name: name, username: username, password: password, kind: kind)
                        try ServerTokenStore.save(token, id: server.id)
                        VelagramStore.shared.servers.append(server); VelagramStore.shared.persist(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            } label: { if busy { ProgressView() } else { Text("Sign in") } }.disabled(busy || address.isEmpty || username.isEmpty)
            Text("Your password is used to sign in and is not saved. The server access token is stored in the iOS Keychain.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Connect server")
            .sheet(isPresented: $quickConnect) {
                NavigationStack { JellyfinQuickConnectView(address: address, name: name) { dismiss() } }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

struct ServerBrowserView: View {
    let server: MediaServer
    var parent: ServerItem?
    @State private var items: [ServerItem] = []
    @State private var query = ""
    @State private var failure: String?
    @State private var loading = true
    @State private var playback: LiveChannel?
    @State private var openingID: String?
    @State private var playbackFailure: String?
    private var client: MediaServerClient { MediaServerClient(server: server, token: ServerTokenStore.load(server.id) ?? "") }
    var body: some View {
        List {
            if loading { ProgressView("Loading library…") }
            if let failure { ContentUnavailableView("Couldn’t load library", systemImage: "wifi.exclamationmark", description: Text(failure)); Button("Retry") { Task { await load() } } }
            ForEach(items) { item in
                if item.isFolder {
                    NavigationLink { ServerBrowserView(server: server, parent: item) } label: { row(item) }
                } else {
                    Button {
                        openingID = item.id
                        Task {
                            defer { openingID = nil }
                            do {
                                let source = try await client.playbackSource(item)
                                try Task.checkCancellation()
                                playback = LiveChannel(id: "server:\(server.id):\(item.id)", name: item.Name, url: source.url, group: server.name, headers: source.headers)
                            } catch { if !Task.isCancelled { playbackFailure = error.localizedDescription } }
                        }
                    } label: {
                        HStack { row(item); if openingID == item.id { ProgressView("Preparing…") } }
                    }.buttonStyle(.plain).disabled(openingID != nil)
                }
            }
            if !loading && failure == nil && items.isEmpty { ContentUnavailableView.search(text: query) }
        }.navigationTitle(parent?.Name ?? server.name).searchable(text: $query)
            .task(id: query) { await load() }.refreshable { await load() }
            .fullScreenCover(item: $playback) { DirectPlayerView(channel: $0) }
            .alert("Couldn’t prepare playback", isPresented: Binding(get: { playbackFailure != nil }, set: { if !$0 { playbackFailure = nil } })) {
                Button("OK", role: .cancel) { playbackFailure = nil }
            } message: { Text(playbackFailure ?? "") }
    }
    private func row(_ item: ServerItem) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: client.image(item)) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: item.isFolder ? "folder.fill" : "play.rectangle.fill").font(.title) }
                .frame(width: 58, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.Name).font(.headline)
                Text(item.detailLabel).font(.caption).foregroundStyle(.secondary)
                if let overview = item.Overview { Text(overview).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
            }
        }
    }
    private func load() async {
        loading = true; failure = nil
        do {
            if !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            let result = try await client.items(parentID: parent?.id, query: query)
            try Task.checkCancellation(); items = result
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        loading = false
    }
}

struct JellyfinQuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    let address: String
    let name: String
    let connected: () -> Void
    @State private var code: String?
    @State private var failure: String?
    @State private var attempt = UUID()
    var body: some View {
        VStack(spacing: 24) {
            if let code {
                Text(code).font(.system(size: 44, weight: .bold, design: .monospaced)).textSelection(.enabled)
                Text("In a signed-in Jellyfin app or the web dashboard, open Quick Connect and enter this code.")
                    .multilineTextAlignment(.center)
                ProgressView("Waiting for approval…")
            } else if failure == nil { ProgressView("Getting a code…") }
            if let failure {
                Text(failure).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { attempt = UUID() }
            }
        }.padding().navigationTitle("Quick Connect")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: attempt) { await connect() }
    }
    private func connect() async {
        code = nil; failure = nil
        do {
            let url = try VelagramHTTP.url(address)
            let enabled: Bool = try await MediaServerClient.quickRequest(url: url, path: "QuickConnect/Enabled")
            guard enabled else {
                failure = "Quick Connect is disabled on this Jellyfin server. Enable it in the server dashboard or sign in with your password."
                return
            }
            let session: MediaServerClient.QuickConnect = try await MediaServerClient.quickRequest(url: url, path: "QuickConnect/Initiate", method: "POST")
            code = session.Code
            let deadline = Date.now.addingTimeInterval(300)
            while Date.now < deadline {
                try await Task.sleep(for: .seconds(5))
                let state: MediaServerClient.QuickConnect = try await MediaServerClient.quickRequest(url: url, path: "QuickConnect/Connect", secret: session.Secret)
                if state.Authenticated {
                    let auth: MediaServerClient.Authentication = try await MediaServerClient.quickRequest(url: url, path: "Users/AuthenticateWithQuickConnect", method: "POST", secret: session.Secret)
                    try Task.checkCancellation()
                    let server = MediaServer(id: UUID(), name: name.isEmpty ? "Jellyfin" : name, url: url, userID: auth.User.Id, kind: .jellyfin)
                    try ServerTokenStore.save(auth.AccessToken, id: server.id)
                    VelagramStore.shared.servers.append(server)
                    VelagramStore.shared.persist()
                    dismiss(); connected()
                    return
                }
            }
            code = nil
            failure = "This code has expired. Try again to get a new code."
        } catch {
            guard !Task.isCancelled else { return }
            code = nil
            failure = "Quick Connect couldn’t complete. \(error.localizedDescription)"
        }
    }
}

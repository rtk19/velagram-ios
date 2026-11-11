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
    var body: some View {
        Form {
            Picker("Server type", selection: $kind) { ForEach(MediaServer.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            TextField("Display name", text: $name)
            TextField("https://your-server:8096", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
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
                        playback = LiveChannel(id: "server:\(server.id):\(item.id)", name: item.Name, url: client.stream(item), group: server.name, headers: client.headers)
                    } label: { row(item) }.buttonStyle(.plain)
                }
            }
            if !loading && failure == nil && items.isEmpty { ContentUnavailableView.search(text: query) }
        }.navigationTitle(parent?.Name ?? server.name).searchable(text: $query)
            .task(id: query) { await load() }.refreshable { await load() }
            .fullScreenCover(item: $playback) { DirectPlayerView(channel: $0) }
    }
    private func row(_ item: ServerItem) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: client.image(item)) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: item.isFolder ? "folder.fill" : "play.rectangle.fill").font(.title) }
                .frame(width: 58, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.Name).font(.headline)
                Text(item.mediaType ?? "Media").font(.caption).foregroundStyle(.secondary)
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

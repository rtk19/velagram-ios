import Foundation
import Observation
import Security
import UIKit

@MainActor @Observable final class TelegramStore {
    static let shared = TelegramStore(transport: TDLibTransport.shared)
    let transport: any TelegramTransport
    var authorization: TelegramJSON = .null
    var chats: [Int64: TelegramChat] = [:]
    var chatOrder: [Int64] = []
    var folders: [TelegramFolder] = []
    var files: [Int: TelegramFile] = [:]
    var thumbnails: [Int: String] = [:]
    var notice: String?
    var busyCount = 0
    var hasMoreChats = true
    var isLoadingChats = false
    var connected = false
    var recentMedia: [TelegramMedia] = []
    var pinned: Set<Int64>
    var chatCategories: [String: TelegramCategory]
    var mediaCategories: [String: TelegramCategory]
    private var updatesTask: Task<Void, Never>?
    private var started = false
    private var sentParameters = false
    private var readyHandled = false
    private var connectionState = "Connecting…"
    private var selectedFolder: Int?
    private var requestedThumbnails: Set<Int> = []
    private let defaults: UserDefaults
    var busy: Bool { busyCount > 0 }
    var ready: Bool { authorization.type == "authorizationStateReady" }
    var status: String { connected ? "Connected" : connectionState }

    init(transport: any TelegramTransport, defaults: UserDefaults = .standard) {
        self.transport = transport; self.defaults = defaults
        recentMedia = defaults.data(forKey: "velagram.telegram.recentMedia").flatMap { try? JSONDecoder().decode([TelegramMedia].self, from: $0) } ?? []
        pinned = Set((defaults.array(forKey: "velagram.telegram.pinned") as? [String] ?? []).compactMap(Int64.init))
        chatCategories = Self.readCategories(defaults, key: "velagram.telegram.chatCategories")
        mediaCategories = Self.readCategories(defaults, key: "velagram.telegram.mediaCategories")
    }
    private static func readCategories(_ defaults: UserDefaults, key: String) -> [String: TelegramCategory] {
        (defaults.dictionary(forKey: key) as? [String: String] ?? [:]).compactMapValues(TelegramCategory.init(rawValue:))
    }
    func restorePreferences() {
        recentMedia = defaults.data(forKey: "velagram.telegram.recentMedia").flatMap { try? JSONDecoder().decode([TelegramMedia].self, from: $0) } ?? []
        pinned = Set((defaults.array(forKey: "velagram.telegram.pinned") as? [String] ?? []).compactMap(Int64.init))
        chatCategories = Self.readCategories(defaults, key: "velagram.telegram.chatCategories")
        mediaCategories = Self.readCategories(defaults, key: "velagram.telegram.mediaCategories")
    }
    func remember(_ media: TelegramMedia) {
        recentMedia.removeAll { $0.id == media.id }; recentMedia.insert(media, at: 0)
        recentMedia = Array(recentMedia.prefix(100)); persist()
    }
    func persist() {
        if let data = try? JSONEncoder().encode(recentMedia) { defaults.set(data, forKey: "velagram.telegram.recentMedia") }
        defaults.set(pinned.map(String.init), forKey: "velagram.telegram.pinned")
        defaults.set(chatCategories.mapValues(\.rawValue), forKey: "velagram.telegram.chatCategories")
        defaults.set(mediaCategories.mapValues(\.rawValue), forKey: "velagram.telegram.mediaCategories")
    }
    func category(_ item: TelegramMedia) -> TelegramCategory {
        TelegramClassification.category(item, chatTitle: chats[item.chatID]?.title ?? "", override: mediaCategories[item.id] ?? chatCategories[String(item.chatID)])
    }
    func mark(_ item: TelegramMedia, as category: TelegramCategory) { mediaCategories[item.id] = category == .all ? nil : category; persist() }
    func mark(_ chat: TelegramChat, as category: TelegramCategory) { chatCategories[String(chat.id)] = category == .all ? nil : category; persist() }
    func togglePin(_ chat: TelegramChat) { if !pinned.insert(chat.id).inserted { pinned.remove(chat.id) }; persist() }

    func start() async {
        guard !started else { return }; started = true
        updatesTask = Task { [weak self, transport] in
            for await update in transport.updates {
                guard !Task.isCancelled else { return }
                await self?.consume(update)
            }
        }
        do { await consume(.request("updateAuthorizationState", ["authorization_state": try await transport.call("getAuthorizationState")])) }
        catch { notice = error.localizedDescription }
    }
    func perform(_ type: String, _ fields: [String: TelegramJSON] = [:]) async {
        busyCount += 1; notice = nil; defer { busyCount -= 1 }
        do { _ = try await transport.call(type, fields) }
        catch { if !Task.isCancelled { notice = error.localizedDescription } }
    }
    func phone(_ text: String) async {
        await perform("setAuthenticationPhoneNumber", ["phone_number": .string(text), "settings": .request("phoneNumberAuthenticationSettings", ["allow_flash_call": .bool(false), "allow_missed_call": .bool(false), "allow_sms_retriever_api": .bool(false)])])
    }
    func requestQR() async { await perform("requestQrCodeAuthentication", ["other_user_ids": .array([])]) }
    func code(_ text: String) async { await perform("checkAuthenticationCode", ["code": .string(text)]) }
    func password(_ text: String) async { await perform("checkAuthenticationPassword", ["password": .string(text)]) }
    func email(_ text: String) async { await perform("setAuthenticationEmailAddress", ["email_address": .string(text)]) }
    func emailCode(_ text: String) async { await perform("checkAuthenticationEmailCode", ["code": .request("emailAddressAuthenticationCode", ["code": .string(text)])]) }
    func resendCode() async { await perform("resendAuthenticationCode", ["reason": .request("resendCodeReasonUserRequest")]) }
    func logOut() async { await perform("logOut") }

    func consume(_ update: TelegramJSON) async {
        switch update.type {
        case "updateAuthorizationState":
            authorization = update["authorization_state"]
            if authorization.type == "authorizationStateWaitTdlibParameters", !sentParameters {
                sentParameters = true
                do { _ = try await transport.call("setTdlibParameters", try parameters()) }
                catch { sentParameters = false; notice = error.localizedDescription }
            } else if authorization.type == "authorizationStateReady", !readyHandled {
                readyHandled = true
                Task { await refreshChats() }
                Task { await CacheManager.shared.maintain(transport: transport) }
            } else if authorization.type == "authorizationStateClosed" {
                sentParameters = false; readyHandled = false
            } else if authorization.type == "authorizationStateWaitPhoneNumber" {
                readyHandled = false; chats = [:]; chatOrder = []; files = [:]; thumbnails = [:]
            }
        case "updateConnectionState":
            connected = update["state"].type == "connectionStateReady"
            connectionState = update["state"].type == "connectionStateWaitingForNetwork" ? "Waiting for network" : "Connecting…"
        case "updateNewChat": if let chat = TelegramChat(update["chat"]) { chats[chat.id] = chat }
        case "updateChatTitle":
            if let id = update["chat_id"].int64 { chats[id]?.title = update["title"].string ?? chats[id]?.title ?? "Chat" }
        case "updateChatPhoto":
            if let id = update["chat_id"].int64 { chats[id]?.photoFileID = update["photo"]["small"]["id"].int64.map(Int.init) }
        case "updateChatFolders":
            folders = update["chat_folders"].array.compactMap { json in
                guard let id = json["id"].int64 else { return nil }
                let title = json["name"]["text"]["text"].string
                    ?? json["title"]["text"].string ?? json["title"].string ?? "Folder"
                return TelegramFolder(id: Int(id), title: title)
            }
        case "updateFile":
            if let file = TelegramFile(update["file"]) {
                files[file.id] = file
                if file.completed, requestedThumbnails.contains(file.id), !file.localPath.isEmpty { thumbnails[file.id] = file.localPath }
            }
        default: break
        }
    }
    private func parameters() throws -> [String: TelegramJSON] {
        guard let url = Bundle.main.url(forResource: "TelegramConfiguration", withExtension: "plist"),
              let configuration = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
              let apiID = configuration["api_id"] as? Int, let apiHash = configuration["api_hash"] as? String, apiID > 0, !apiHash.isEmpty else {
            throw TelegramError(code: -1, message: "Telegram application configuration is missing.")
        }
        // Auth databases are credentials: keep them outside the JSON backup boundary.
        let database = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "VelagramTelegramSession")
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "VelagramTelegram")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var databaseURL = database; try databaseURL.setResourceValues(excluded)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: database.path)
        return ["use_test_dc": .bool(false), "database_directory": .string(database.path), "files_directory": .string(cache.path),
            "database_encryption_key": .string(try TelegramSessionKey.loadOrCreate().base64EncodedString()),
            "use_file_database": .bool(true), "use_chat_info_database": .bool(true), "use_message_database": .bool(true), "use_secret_chats": .bool(false),
            "api_id": .integer(Int64(apiID)), "api_hash": .string(apiHash), "system_language_code": .string(Locale.current.language.languageCode?.identifier ?? "en"),
            "device_model": .string(UIDevice.current.model), "system_version": .string(UIDevice.current.systemVersion), "application_version": .string("Velagram iOS " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.0"))]
    }
    func refreshChats(folderID: Int? = nil, more: Bool = false) async {
        guard ready, !isLoadingChats else { return }
        isLoadingChats = true; defer { isLoadingChats = false }
        let sameList = selectedFolder == folderID
        selectedFolder = folderID
        let list: TelegramJSON = folderID.map { .request("chatListFolder", ["chat_folder_id": .integer(Int64($0))]) } ?? .request("chatListMain")
        let limit = more && sameList ? chatOrder.count + 100 : 100
        do {
            do { _ = try await transport.call("loadChats", ["chat_list": list, "limit": .integer(100)]) }
            catch let error as TelegramError where error.code == 404 { /* all chats are loaded */ }
            let response = try await transport.call("getChats", ["chat_list": list, "limit": .integer(Int64(limit))])
            let ids = response["chat_ids"].array.compactMap(\.int64)
            for id in ids where chats[id] == nil {
                if let chat = TelegramChat(try await transport.call("getChat", ["chat_id": .integer(id)])) { chats[id] = chat }
            }
            chatOrder = ids; hasMoreChats = ids.count >= limit
        } catch { if !Task.isCancelled { notice = error.localizedDescription } }
    }
    func searchChats(_ query: String) async throws -> [TelegramChat] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let response = try await transport.call("searchChats", ["query": .string(query), "limit": .integer(100)])
        var result: [TelegramChat] = []
        for id in response["chat_ids"].array.compactMap(\.int64) {
            if let chat = chats[id] { result.append(chat) }
            else if let chat = TelegramChat(try await transport.call("getChat", ["chat_id": .integer(id)])) { chats[id] = chat; result.append(chat) }
        }
        return result
    }
    func openPublicChat(_ input: String) async throws -> TelegramChat {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let response: TelegramJSON
        if value.contains("t.me/+") || value.contains("joinchat/") {
            // Checking a link doesn't join a group. Joining requires an explicit UI action.
            let info = try await transport.call("checkChatInviteLink", ["invite_link": .string(value)])
            guard let id = info["chat_id"].int64, id != 0 else { throw TelegramError(code: -1, message: "This is a private invitation. Use Join group to request access.") }
            response = try await transport.call("getChat", ["chat_id": .integer(id)])
        } else {
            let username = value.replacingOccurrences(of: "https://t.me/", with: "").replacingOccurrences(of: "http://t.me/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "@/"))
            response = try await transport.call("searchPublicChat", ["username": .string(username)])
        }
        guard let chat = TelegramChat(response) else { throw TelegramError(code: -1, message: "Chat not found.") }
        chats[chat.id] = chat; return chat
    }
    func join(_ link: String) async throws -> TelegramChat {
        let response = try await transport.call("joinChatByInviteLink", ["invite_link": .string(link)])
        guard let chat = TelegramChat(response) else { throw TelegramError(code: -1, message: "Telegram did not return a chat.") }
        chats[chat.id] = chat; return chat
    }
    func loadThumbnail(_ id: Int) async {
        guard thumbnails[id] == nil, !requestedThumbnails.contains(id), ready else { return }
        requestedThumbnails.insert(id)
        do {
            let file = try await transport.call("downloadFile", ["file_id": .integer(Int64(id)), "priority": .integer(1), "offset": .integer(0), "limit": .integer(0), "synchronous": .bool(false)])
            if let value = TelegramFile(file) { files[id] = value; if value.completed { thumbnails[id] = value.localPath } }
        } catch { requestedThumbnails.remove(id) }
    }
}

enum TelegramSessionKey {
    static func loadOrCreate() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.refael.Velagram.telegram", kSecAttrAccount as String: "database-key"]
        var lookup = query; lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let key = result as? Data { return key }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TelegramError(code: -1, message: "Could not create the Telegram session encryption key.") }
        let key = Data(bytes)
        var attributes = query; attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return key
    }
}

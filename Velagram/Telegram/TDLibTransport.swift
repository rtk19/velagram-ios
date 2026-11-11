import Foundation
import TDLibFramework

/// TDLib documents send as thread-safe and receive as a single-consumer API.
/// The dedicated receiver copies C strings before the next receive call.
final class TDLibTransport: TelegramTransport, @unchecked Sendable {
    static let shared = TDLibTransport()
    let updates: AsyncStream<TelegramJSON>
    private let continuation: AsyncStream<TelegramJSON>.Continuation
    private var clientID: Int32
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<TelegramJSON, Error>] = [:]
    private var cancelled: Set<String> = []
    private var closed = false
    private var receiverStarted = false

    private init() {
        let stream = AsyncStream<TelegramJSON>.makeStream()
        updates = stream.stream; continuation = stream.continuation
        clientID = td_create_client_id()
        // Never print Telegram requests, login codes, messages, or session keys.
        let log = "{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":0}"
        log.withCString { _ = td_execute($0) }
    }
    private func startReceivingIfNeeded() {
        let shouldStart = lock.withLock {
            guard !receiverStarted else { return false }; receiverStarted = true; return true
        }
        guard shouldStart else { return }
        DispatchQueue(label: "Velagram.Telegram.receive", qos: .userInitiated).async { [self] in
            while !isClosed {
                guard let pointer = td_receive(0.5) else { continue }
                let data = Data(String(cString: pointer).utf8)
                guard let response = try? JSONDecoder().decode(TelegramJSON.self, from: data),
                      response["@client_id"].int64 == Int64(currentClientID) else { continue }
                deliver(response)
            }
            continuation.finish()
        }
    }
    private var isClosed: Bool { lock.withLock { closed } }
    private var currentClientID: Int32 { lock.withLock { clientID } }
    func request(_ query: TelegramJSON, timeout: TimeInterval = 40) async throws -> TelegramJSON {
        let id = UUID().uuidString
        let data = try JSONEncoder().encode(query.setting("@extra", .string(id)))
        let json = String(decoding: data, as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { promise in
                let shouldSend = lock.withLock {
                    if cancelled.remove(id) != nil || Task.isCancelled {
                        promise.resume(throwing: CancellationError()); return false
                    }
                    if closed { promise.resume(throwing: TelegramError(code: -1, message: "Telegram is closed. Reopen Velagram to reconnect.")); return false }
                    pending[id] = promise; return true
                }
                guard shouldSend else { return }
                json.withCString { td_send(currentClientID, $0) }
                // Start the single receiver after the first request initializes
                // the native client, rather than during UI construction.
                startReceivingIfNeeded()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.fail(id, error: TelegramError(code: 408, message: "Telegram did not respond in time. Check your connection and try again."))
                }
            }
        } onCancel: { [self] in
            let promise = lock.withLock {
                cancelled.insert(id)
                return pending.removeValue(forKey: id)
            }
            promise?.resume(throwing: CancellationError())
        }
    }
    private func fail(_ id: String, error: Error) {
        lock.withLock { pending.removeValue(forKey: id) }?.resume(throwing: error)
    }
    private func deliver(_ response: TelegramJSON) {
        if let id = response["@extra"].string {
            let promise = lock.withLock { cancelled.remove(id); return pending.removeValue(forKey: id) }
            if response.type == "error" {
                promise?.resume(throwing: TelegramError(code: response["code"].int, message: response["message"].string ?? "Telegram error"))
            } else { promise?.resume(returning: response) }
        } else if response.type.hasPrefix("authorizationState") {
            continuation.yield(.request("updateAuthorizationState", ["authorization_state": response]))
        } else { continuation.yield(response) }
        if response.type == "updateAuthorizationState", response["authorization_state"].type == "authorizationStateClosed" {
            let promises = lock.withLock { let all = Array(pending.values); pending.removeAll(); cancelled.removeAll(); clientID = td_create_client_id(); return all }
            promises.forEach { $0.resume(throwing: TelegramError(code: -1, message: "Telegram session was restarted.")) }
            "{\"@type\":\"getAuthorizationState\"}".withCString { td_send(currentClientID, $0) }
        }
    }
}

import Foundation
import Network

public struct ProxyRuntimeStatus: Sendable {
    public let isRunning: Bool
    public let baseURL: String
    public let message: String
}

public final class CodexProxyServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.xu.codex-api.proxy")
    private let logger: ProxyLogger
    private let upstream = UpstreamClient()
    private let oauthService: CodexOAuthService
    private var listener: NWListener?
    private var settings = ProxySettings()
    private let lock = NSLock()

    public var onStatusChange: (@Sendable (ProxyRuntimeStatus) -> Void)?
    public var onOAuthLogin: (@Sendable (CodexOAuthTokenBundle) -> Void)?

    public init(logger: ProxyLogger = ProxyLogger(), oauthService: CodexOAuthService = CodexOAuthService()) {
        self.logger = logger
        self.oauthService = oauthService
    }

    public func start(settings: ProxySettings) throws {
        lock.lock()
        if listener != nil, self.settings.listenPort == settings.listenPort {
            self.settings = settings
            lock.unlock()
            logger.append(.info, "proxy settings updated")
            onStatusChange?(ProxyRuntimeStatus(isRunning: true, baseURL: settings.baseURL, message: "Running"))
            return
        }
        let old = listener
        listener = nil
        lock.unlock()
        old?.cancel()

        guard let port = NWEndpoint.Port(rawValue: settings.listenPort) else {
            throw ProxyError.badRequest("invalid listen port")
        }

        let listener = try NWListener(using: .tcp, on: port)
        listener.service = nil
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        lock.lock()
        self.listener = listener
        self.settings = settings
        lock.unlock()

        listener.start(queue: queue)
        logger.append(.info, "proxy listening at \(settings.baseURL)")
        onStatusChange?(ProxyRuntimeStatus(isRunning: true, baseURL: settings.baseURL, message: "Running"))
    }

    public func stop() {
        lock.lock()
        let old = listener
        listener = nil
        lock.unlock()
        old?.cancel()
        onStatusChange?(ProxyRuntimeStatus(isRunning: false, baseURL: settings.baseURL, message: "Stopped"))
    }

    public func update(settings: ProxySettings) {
        lock.lock()
        self.settings = settings
        let running = listener != nil
        lock.unlock()
        logger.append(.info, "proxy settings updated")
        onStatusChange?(ProxyRuntimeStatus(isRunning: running, baseURL: settings.baseURL, message: running ? "Running" : "Stopped"))
    }

    public func currentStatus() -> ProxyRuntimeStatus {
        lock.lock()
        let running = listener != nil
        let baseURL = settings.baseURL
        lock.unlock()
        return ProxyRuntimeStatus(isRunning: running, baseURL: baseURL, message: running ? "Running" : "Stopped")
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            do {
                let request = try await receiveRequest(from: connection)
                let response = try await route(request, connection: connection)
                if let response {
                    try await connection.sendData(HTTPParser.serializeResponse(response))
                }
            } catch {
                let response = errorResponse(error)
                try? await connection.sendData(HTTPParser.serializeResponse(response))
            }
            connection.cancel()
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            onStatusChange?(ProxyRuntimeStatus(isRunning: true, baseURL: settings.baseURL, message: "Running"))
        case .failed(let error):
            logger.append(.error, "listener failed: \(error)")
            onStatusChange?(ProxyRuntimeStatus(isRunning: false, baseURL: settings.baseURL, message: error.localizedDescription))
        case .cancelled:
            onStatusChange?(ProxyRuntimeStatus(isRunning: false, baseURL: settings.baseURL, message: "Stopped"))
        default:
            break
        }
    }

    private func receiveRequest(from connection: NWConnection) async throws -> HTTPRequest {
        var data = Data()
        while !HTTPParser.hasCompleteRequest(data) {
            guard let chunk = try await connection.receiveData(maximumLength: 64 * 1024), !chunk.isEmpty else {
                throw ProxyError.badRequest("connection closed before request completed")
            }
            data.append(chunk)
            if data.count > 64 * 1024 * 1024 {
                throw ProxyError.badRequest("request too large")
            }
        }
        return try HTTPParser.parseRequest(from: data)
    }

    private func route(_ request: HTTPRequest, connection: NWConnection) async throws -> HTTPResponse? {
        let currentSettings = settingsSnapshot()

        if request.method == "OPTIONS" {
            return HTTPResponse(statusCode: 204, reason: "No Content")
        }

        if request.method == "GET", request.path == "/auth/callback" {
            return try await handleOAuthCallback(request)
        }

        if !currentSettings.proxyKey.isEmpty && request.bearerToken != currentSettings.proxyKey {
            throw ProxyError.unauthorized
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            return try jsonResponse([
                "status": "ok",
                "base_url": currentSettings.openAIBaseURL,
                "upstream": currentSettings.normalizedUpstreamBaseURL
            ])
        case ("GET", "/v1/models"):
            return try jsonResponse(modelsPayload(settings: currentSettings))
        case ("POST", "/v1/responses"):
            return try await handleResponses(request, settings: currentSettings, connection: connection, compact: false)
        case ("POST", "/v1/responses/compact"):
            return try await handleResponses(request, settings: currentSettings, connection: connection, compact: true)
        case ("POST", "/v1/chat/completions"):
            return try await handleChatCompletions(request, settings: currentSettings, connection: connection)
        case ("POST", "/v1/completions"):
            return try await handleCompletions(request, settings: currentSettings, connection: connection)
        default:
            throw ProxyError.notFound
        }
    }

    private func handleOAuthCallback(_ request: HTTPRequest) async throws -> HTTPResponse {
        let tokens = try await oauthService.handleCallback(query: request.query)
        logger.append(.info, "OpenAI OAuth login succeeded for \(tokens.email.isEmpty ? "account" : tokens.email)")
        onOAuthLogin?(tokens)
        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>CodexAPI Login Complete</title>
            <style>
              body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 48px; line-height: 1.45; }
              code { background: #f2f2f2; padding: 2px 5px; border-radius: 4px; }
            </style>
          </head>
          <body>
            <h1>Login complete</h1>
            <p>CodexAPI received the OpenAI OAuth token. You can close this window.</p>
            <script>setTimeout(function(){ window.close(); }, 1200);</script>
          </body>
        </html>
        """
        return HTTPResponse(statusCode: 200, reason: "OK", headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private func handleResponses(_ request: HTTPRequest, settings: ProxySettings, connection: NWConnection, compact: Bool) async throws -> HTTPResponse? {
        let original = try JSONHelper.object(from: request.body)
        let model = JSONHelper.string(original["model"]) ?? settings.defaultModelID
        let clientWantsStream = JSONHelper.bool(original["stream"])
        let upstreamPath = compact ? "/responses/compact" : "/responses"
        var upstreamBody = OpenAICompatTranslator.responsesToCodex(original, model: model, stream: !compact)
        if settings.injectImageGenerationTool {
            upstreamBody = OpenAICompatTranslator.ensureImageGenerationTool(in: upstreamBody, model: model)
        }

        if clientWantsStream && !compact {
            try await streamResponses(upstreamBody: upstreamBody, request: request, settings: settings, connection: connection)
            return nil
        }

        let response = try await upstream.data(settings: settings, request: request, path: upstreamPath, body: upstreamBody, stream: !compact)
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw ProxyError.upstreamStatus(response.statusCode, response.body)
        }

        if compact {
            return HTTPResponse(statusCode: 200, reason: "OK", headers: ["Content-Type": response.headers["Content-Type"] ?? "application/json"], body: response.body)
        }

        let completed = try completedEvent(from: response.body)
        guard let responseObject = OpenAICompatTranslator.responseObject(fromCompletedEvent: completed) else {
            throw ProxyError.network("upstream stream ended before response.completed")
        }
        return try jsonResponse(responseObject)
    }

    private func handleChatCompletions(_ request: HTTPRequest, settings: ProxySettings, connection: NWConnection) async throws -> HTTPResponse? {
        let original = try JSONHelper.object(from: request.body)
        let model = JSONHelper.string(original["model"]) ?? settings.defaultModelID
        let clientWantsStream = JSONHelper.bool(original["stream"])
        var upstreamBody = OpenAICompatTranslator.chatCompletionsToCodex(original, model: model, stream: true)
        if settings.injectImageGenerationTool {
            upstreamBody = OpenAICompatTranslator.ensureImageGenerationTool(in: upstreamBody, model: model)
        }

        if clientWantsStream {
            try await streamChatCompletions(upstreamBody: upstreamBody, originalRequest: original, model: model, request: request, settings: settings, connection: connection)
            return nil
        }

        let response = try await upstream.data(settings: settings, request: request, path: "/responses", body: upstreamBody, stream: true)
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw ProxyError.upstreamStatus(response.statusCode, response.body)
        }
        let completed = try completedEvent(from: response.body)
        return try jsonResponse(OpenAICompatTranslator.chatCompletion(fromCompletedEvent: completed, originalRequest: original))
    }

    private func handleCompletions(_ request: HTTPRequest, settings: ProxySettings, connection: NWConnection) async throws -> HTTPResponse? {
        let original = try JSONHelper.object(from: request.body)
        let prompt = JSONHelper.string(original["prompt"]) ?? "Complete this:"
        var chat: JSONObject = [
            "model": JSONHelper.string(original["model"]) ?? settings.defaultModelID,
            "stream": JSONHelper.bool(original["stream"]),
            "messages": [[
                "role": "user",
                "content": prompt
            ]]
        ]
        for key in ["temperature", "top_p", "frequency_penalty", "presence_penalty", "reasoning_effort"] {
            if let value = original[key] {
                chat[key] = value
            }
        }
        let replacement = HTTPRequest(
            method: request.method,
            target: request.target,
            path: request.path,
            query: request.query,
            version: request.version,
            headers: request.headers,
            body: try JSONHelper.data(chat)
        )
        return try await handleChatCompletions(replacement, settings: settings, connection: connection)
    }

    private func streamResponses(upstreamBody: JSONObject, request: HTTPRequest, settings: ProxySettings, connection: NWConnection) async throws {
        let stream = try await upstream.stream(settings: settings, request: request, path: "/responses", body: upstreamBody)
        guard stream.statusCode >= 200 && stream.statusCode < 300 else {
            var body = Data()
            for try await byte in stream.bytes {
                body.append(byte)
            }
            throw ProxyError.upstreamStatus(stream.statusCode, body)
        }

        let headers = [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache"
        ]
        try await connection.sendData(HTTPParser.streamHeader(headers: headers))

        var decoder = SSEDecoder()
        var accumulator = CodexCompletedAccumulator()
        for try await byte in stream.bytes {
            for frame in decoder.append(Data([byte])) {
                guard let payload = try? JSONHelper.object(from: frame.data) else {
                    try await connection.sendData(frame.serialized())
                    continue
                }
                let patched = accumulator.observe(payload)
                try await connection.sendData(SSEFrame(event: frame.event, data: try JSONHelper.data(patched)).serialized())
            }
        }
        for frame in decoder.flush() {
            guard let payload = try? JSONHelper.object(from: frame.data) else {
                try await connection.sendData(frame.serialized())
                continue
            }
            let patched = accumulator.observe(payload)
            try await connection.sendData(SSEFrame(event: frame.event, data: try JSONHelper.data(patched)).serialized())
        }
        try await connection.sendData(Data("\n".utf8))
    }

    private func streamChatCompletions(upstreamBody: JSONObject, originalRequest: JSONObject, model: String, request: HTTPRequest, settings: ProxySettings, connection: NWConnection) async throws {
        let stream = try await upstream.stream(settings: settings, request: request, path: "/responses", body: upstreamBody)
        guard stream.statusCode >= 200 && stream.statusCode < 300 else {
            var body = Data()
            for try await byte in stream.bytes {
                body.append(byte)
            }
            throw ProxyError.upstreamStatus(stream.statusCode, body)
        }

        let headers = [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache"
        ]
        try await connection.sendData(HTTPParser.streamHeader(headers: headers))

        var decoder = SSEDecoder()
        var accumulator = CodexCompletedAccumulator()
        var translator = ChatStreamTranslator(requestModel: model, originalRequest: originalRequest)
        for try await byte in stream.bytes {
            for frame in decoder.append(Data([byte])) {
                guard let payload = try? JSONHelper.object(from: frame.data) else {
                    continue
                }
                let patched = accumulator.observe(payload)
                for chunk in translator.translate(payload: patched) {
                    let json = try JSONHelper.data(chunk)
                    try await connection.sendData(Data("data: ".utf8) + json + Data("\n\n".utf8))
                }
            }
        }
        for frame in decoder.flush() {
            guard let payload = try? JSONHelper.object(from: frame.data) else {
                continue
            }
            let patched = accumulator.observe(payload)
            for chunk in translator.translate(payload: patched) {
                let json = try JSONHelper.data(chunk)
                try await connection.sendData(Data("data: ".utf8) + json + Data("\n\n".utf8))
            }
        }
        try await connection.sendData(Data("data: [DONE]\n\n".utf8))
    }

    private func completedEvent(from data: Data) throws -> JSONObject {
        if let object = try? JSONHelper.object(from: data),
           JSONHelper.string(object["type"]) == "response.completed" {
            return object
        }

        var decoder = SSEDecoder()
        var accumulator = CodexCompletedAccumulator()
        var completed: JSONObject?
        for frame in decoder.append(data) + decoder.flush() {
            guard let payload = try? JSONHelper.object(from: frame.data) else {
                continue
            }
            let patched = accumulator.observe(payload)
            if JSONHelper.string(patched["type"]) == "response.completed" {
                completed = patched
            }
        }
        guard let completed else {
            throw ProxyError.network("response.completed was not found")
        }
        return completed
    }

    private func modelsPayload(settings: ProxySettings) -> JSONObject {
        [
            "object": "list",
            "data": settings.effectiveModelDescriptors.map(\.openAIModelObject)
        ]
    }

    private func settingsSnapshot() -> ProxySettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    private func jsonResponse(_ object: JSONObject, statusCode: Int = 200, reason: String = "OK") throws -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, reason: reason, headers: ["Content-Type": "application/json"], body: try JSONHelper.data(object))
    }

    private func errorResponse(_ error: Error) -> HTTPResponse {
        let status: Int
        let message: String
        let code: String
        let type: String

        if let proxyError = error as? ProxyError {
            switch proxyError {
            case .badRequest(let text), .invalidJSON(let text):
                status = 400
                message = text
                code = "bad_request"
                type = "invalid_request_error"
            case .unauthorized:
                status = 401
                message = "Unauthorized"
                code = "unauthorized"
                type = "authentication_error"
            case .notFound:
                status = 404
                message = "Not found"
                code = "not_found"
                type = "invalid_request_error"
            case .upstreamStatus(let upstreamStatus, let body):
                status = upstreamStatus
                message = String(data: body, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: upstreamStatus)
                code = upstreamStatus == 401 ? "auth_unavailable" : "upstream_error"
                type = upstreamStatus == 401 ? "authentication_error" : "api_error"
            case .missingUpstreamToken:
                status = 401
                message = "Set a Codex upstream token in the tray settings or pass Authorization: Bearer <token>."
                code = "missing_upstream_token"
                type = "authentication_error"
            case .network(let text):
                status = 502
                message = text
                code = "upstream_error"
                type = "api_error"
            }
        } else {
            status = 500
            message = error.localizedDescription
            code = "internal_error"
            type = "server_error"
        }

        logger.append(status >= 500 ? .error : .warning, message)
        let payload: JSONObject = [
            "error": [
                "message": message,
                "type": type,
                "code": code
            ]
        ]
        let body = (try? JSONHelper.data(payload)) ?? Data()
        return HTTPResponse(statusCode: status, reason: HTTPURLResponse.localizedString(forStatusCode: status), headers: ["Content-Type": "application/json"], body: body)
    }
}

private extension NWConnection {
    func receiveData(maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if isComplete && (data == nil || data?.isEmpty == true) {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    func sendData(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

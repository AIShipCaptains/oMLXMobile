import Foundation

enum APIError: LocalizedError {
    case badURL(String)
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Invalid server URL: \(s)"
        case .http(let status, let body):
            let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
            return "HTTP \(status): \(preview)"
        }
    }
}

struct APIClient {
    let base: URL
    let apiKey: String?

    // MARK: Request helpers

    private func request(path: String, method: String = "GET", bodyData: Data? = nil) throws -> URLRequest {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.badURL(base.absoluteString)
        }
        comps.path = comps.path + path
        guard let url = comps.url else { throw APIError.badURL(base.absoluteString + path) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let bodyData {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
        }
        return req
    }

    // MARK: GET /v1/models

    func listModels() async throws -> [String] {
        let req = try request(path: "/v1/models")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.http(status: -1, body: "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map(\.id)
    }

    // MARK: GET /health (oMLX dashboard info; generic for other servers)

    struct HealthResult: Identifiable {
        let statusCode: Int
        let body: String
        var id: Int { statusCode }
        var isOK: Bool { (200..<300).contains(statusCode) }
    }

    func health() async throws -> HealthResult {
        let req = try request(path: "/health")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.http(status: -1, body: "no response") }
        return HealthResult(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    // MARK: POST /v1/chat/completions (streaming)

    struct ChatTurn: Encodable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatTurn]
        let stream: Bool
        let temperature: Double?
    }

    private struct ModelsResponse: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    private struct ChatChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }

    func streamChat(messages: [ChatTurn], model: String, temperature: Double? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bodyData = try JSONEncoder().encode(
                        ChatRequest(model: model, messages: messages, stream: true, temperature: temperature)
                    )
                    let req = try request(
                        path: "/v1/chat/completions",
                        method: "POST",
                        bodyData: bodyData
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 2000 { break }
                        }
                        throw APIError.http(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data),
                              let delta = chunk.choices.first?.delta.content,
                              !delta.isEmpty else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - oMLX Admin API (server control, stats, model management)

struct AdminModel: Identifiable {
    let id: String
    let name: String
    let loaded: Bool?
    let sizeBytes: Int64?

    init?(from dict: [String: Any]) {
        guard let id = (dict["id"] ?? dict["name"] ?? dict["model"]) as? String else { return nil }
        self.id = id
        self.name = (dict["display_name"] ?? dict["title"]) as? String ?? id
        self.loaded = (dict["loaded"] ?? dict["is_loaded"] ?? dict["is_loaded_flag"]) as? Bool
        if let n = dict["size_bytes"] as? Int64 {
            sizeBytes = n
        } else if let n = dict["size_bytes"] as? Int {
            sizeBytes = Int64(n)
        } else {
            sizeBytes = nil
        }
    }
}

extension APIClient {
    private func adminRequest(path: String, method: String = "GET") async throws -> Data {
        var req = try request(path: path, method: method)
        if method == "POST" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, body: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func adminJSON(path: String, method: String = "GET") async throws -> Any {
        let data = try await adminRequest(path: path, method: method)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func encodedPath(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }

    // Server controls
    func restartServer() async throws {
        _ = try await adminRequest(path: "/admin/api/server/restart", method: "POST")
    }

    func reloadServer() async throws {
        _ = try await adminRequest(path: "/admin/api/reload", method: "POST")
    }

    func clearHotCache() async throws {
        _ = try await adminRequest(path: "/admin/api/hot-cache/clear", method: "POST")
    }

    // Stats — generic dictionaries (schema varies across oMLX versions)
    func adminStats() async throws -> Any {
        try await adminJSON(path: "/admin/api/stats")
    }

    func adminUsage() async throws -> Any {
        try await adminJSON(path: "/admin/api/usage")
    }

    // Models
    func adminModels() async throws -> [AdminModel] {
        let obj = try await adminJSON(path: "/admin/api/models")
        var dicts: [[String: Any]] = []
        if let array = obj as? [[String: Any]] {
            dicts = array
        } else if let dict = obj as? [String: Any] {
            for key in ["models", "data", "items", "local_models"] {
                if let array = dict[key] as? [[String: Any]] { dicts = array; break }
            }
            if dicts.isEmpty, let inner = dict["models"] as? [String: Any] {
                dicts = inner.compactMap { key, value in
                    (value as? [String: Any]).map { $0.merging(["id": key]) { _, new in new } }
                }
            }
        }
        return dicts.compactMap(AdminModel.init)
    }

    func modelStatus() async throws -> Any {
        try await adminJSON(path: "/v1/models/status")
    }

    func loadModel(_ id: String) async throws {
        _ = try await adminRequest(path: "/admin/api/models/\(encodedPath(id))/load", method: "POST")
    }

    func unloadModel(_ id: String) async throws {
        _ = try await adminRequest(path: "/admin/api/models/\(encodedPath(id))/unload", method: "POST")
    }
}
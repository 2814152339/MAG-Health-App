import Foundation

struct RemoteJob: Codable, Sendable {
    var id: String
    var stage: String
    var status: String
    var progress: Double
    var reportId: String?
    var error: String?
}

struct APIClient: Sendable {
    let baseURL: URL
    let token: String
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    init(url: String, token: String) throws {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased(), let host = u.host,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              scheme == "https" || (scheme == "http" && Self.isLocal(host)) else {
            throw AnalysisError.network("请填写 HTTPS 地址，或同一 Wi-Fi 下的局域网 HTTP 地址。")
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalysisError.network("请先填写服务端访问令牌。")
        }
        baseURL = u
        self.token = token
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let parts = labels.compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, type: String = "application/json") -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 30)
        r.httpMethod = method
        r.httpBody = body
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(type, forHTTPHeaderField: "Content-Type")
        return r
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request)
        guard data.count <= 12_000_000 else { throw AnalysisError.network("服务端响应过大。") }
        guard let http = response as? HTTPURLResponse else { throw AnalysisError.network("没有收到服务端响应。") }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AnalysisError.network("服务端令牌无效，请在设置中更新。") }
            if http.statusCode == 404 { throw AnalysisError.network("服务端记录不存在，或当前令牌无权访问。") }
            // Deliberately do not echo arbitrary server bodies or tokens into user-visible logs.
            throw AnalysisError.network("服务端请求失败（HTTP \(http.statusCode)）。")
        }
        return data
    }

    func upload(_ jpeg: Data, key: String) async throws -> String {
        let boundary = "Ruyuan-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        struct Upload: Decodable { let assetId: String }
        var req = request("v1/uploads", method: "POST", body: body, type: "multipart/form-data; boundary=\(boundary)")
        req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        return try JSONDecoder().decode(Upload.self, from: await send(req)).assetId
    }

    func consent() async throws -> String {
        struct Consent: Decodable { let consentId: String }
        let body = try JSONSerialization.data(withJSONObject: ["purpose": "skin_appearance_analysis", "version": "1.0"])
        return try JSONDecoder().decode(Consent.self, from: await send(request("v1/consents", method: "POST", body: body))).consentId
    }

    func create(asset: String, consent: String, key: String) async throws -> RemoteJob {
        let body = try JSONSerialization.data(withJSONObject: ["assetId": asset, "consentId": consent, "idempotencyKey": key])
        return try JSONDecoder().decode(RemoteJob.self, from: await send(request("v1/analyses", method: "POST", body: body)))
    }

    func job(_ id: String) async throws -> RemoteJob {
        try Self.validateID(id)
        return try JSONDecoder().decode(RemoteJob.self, from: await send(request("v1/analyses/\(id)")))
    }

    func report(_ id: String) async throws -> AnalysisReport {
        try Self.validateID(id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let text = try container.decode(String.self)
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fmt.date(from: text) { return date }
            fmt.formatOptions = [.withInternetDateTime]
            if let date = fmt.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected ISO8601 date")
        }
        return try decoder.decode(AnalysisReport.self, from: await send(request("v1/reports/\(id)")))
    }

    func deleteJob(_ id: String) async throws {
        try Self.validateID(id)
        _ = try await send(request("v1/analyses/\(id)", method: "DELETE"))
    }
    func deleteReport(_ id: String) async throws {
        try Self.validateID(id)
        _ = try await send(request("v1/reports/\(id)", method: "DELETE"))
    }
    func deleteAsset(_ id: String) async throws {
        try Self.validateID(id)
        _ = try await send(request("v1/assets/\(id)", method: "DELETE"))
    }
    func deleteOperation(_ key: String) async throws {
        try Self.validateID(key)
        _ = try await send(request("v1/operations/\(key)", method: "DELETE"))
    }
    private static func validateID(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !value.isEmpty, value.count <= 128, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AnalysisError.network("服务端返回了无效记录编号。")
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a photograph or bearer token through a redirect.
        completionHandler(nil)
    }
}

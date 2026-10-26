import CryptoKit
import Foundation

enum NativeStage: String {
    case prepareStart, playURLReady, videoTrackReady, audioTrackReady, playerReady
    case prepareFailure, playerFailure, segmentReady
    case downloadFinished, downloadFailed
    case offlineReady
    case playbackResigned, playbackBackgrounded, playbackForegrounding, playbackActivated
    case fullscreenChanged
    case playbackWaiting, playbackRunning
    case supportReady
    case subtitleReady
    case searchPosition
    case historyReceived, historyReported, historyFailed
    case libraryReceived, libraryFailed, libraryShape
    case boot, accountRestored, followingStart, followingReceived, followingParsed, relationsRead, followingVerified,
        followingDisplayed, followingCancelled, followingFailed
}
enum NativeTrace {
    #if DEBUG
        private static let lock = NSLock()
        private static let writer = DispatchQueue(label: "app.bilight.diagnostics", qos: .utility)
        private static var records: [JSON] = []
    #endif
    /// Development diagnostics contain fixed stages and numeric counts/status, never payloads or credentials.
    static func mark(_ stage: NativeStage, _ fields: [String: Int] = [:]) {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["BILIGHT_ISOLATED_TESTS"] != "1" else { return }
            let time = Date().timeIntervalSince1970
            writer.async {
                lock.withLock {
                    if stage == .boot { records = [] }
                    records.append(["time": time, "stage": stage.rawValue, "counts": fields])
                    records = Array(records.suffix(64))
                    if let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                        let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
                    {
                        try? data.write(
                            to: directory.appendingPathComponent("BilightDiagnostics.json"),
                            options: [.atomic, .completeFileProtection])
                    }
                }
            }
        #endif
    }
}

final class BiliRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, BiliHTTP.trusted(url) else {
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(next)
    }
}
actor BiliHTTP {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
    private static let mixin = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12,
        38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62,
        11, 36, 20, 34, 44, 52,
    ]
    private let session: URLSession
    private let vault: SessionVault
    private var cookies: [StoredCookie] = []
    private var validatingLogin = false
    private var generation = UUID()
    private var key: (String, Date)?
    private var keyTask: Task<String, Error>?
    private var deviceTask: Task<Void, Error>?
    init(configuration: URLSessionConfiguration = .ephemeral, vault: SessionVault = DeviceSessionVault()) {
        self.vault = vault
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: BiliRedirectPolicy(), delegateQueue: nil)
    }
    nonisolated static func trusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host, url.user == nil, url.password == nil,
            url.port == nil || url.port == 443
        else { return false }
        return host == "bilibili.com" || host.hasSuffix(".bilibili.com") || host == "b23.tv"
    }
    nonisolated static func encode(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
    nonisolated static func signedQuery(_ query: [String: String], key: String, timestamp: Int) -> String {
        var values = query
        values["wts"] = "\(timestamp)"
        values.removeValue(forKey: "w_rid")
        let text = values.keys.sorted().map {
            "\(encode($0))=\(encode(values[$0]!.replacingOccurrences(of: "[!'()*]", with: "", options: .regularExpression)))"
        }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((text + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return text + "&w_rid=" + digest
    }
    func restore() throws { cookies = try vault.load() }
    func version() -> UUID { generation }
    func check(_ version: UUID) throws {
        guard version == generation else { throw BiliFailure(code: "ACCOUNT_CHANGED", message: "账号已变化，请重新打开页面。") }
    }
    func logout() {
        validatingLogin = false
        generation = UUID()
        cookies = []
        key = nil
        keyTask?.cancel()
        keyTask = nil
        deviceTask?.cancel()
        deviceTask = nil
        vault.remove()
    }
    func csrf() throws -> String {
        guard
            let value = cookies.first(where: {
                $0.name == "bili_jct" && $0.matches(URL(string: "https://api.bilibili.com/")!)
            })?.value, !value.isEmpty,
            cookies.contains(where: { $0.name == "SESSDATA" && $0.matches(URL(string: "https://api.bilibili.com/")!) })
        else { throw BiliFailure(code: "-101", message: "请先登录 B 站账号。") }
        return value
    }
    func acceptLogin(_ candidates: [HTTPCookie]) async throws -> User {
        let valid = candidates.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "bilibili.com" || domain.hasSuffix(".bilibili.com")
        }
        guard valid.contains(where: { $0.name == "SESSDATA" }), valid.contains(where: { $0.name == "bili_jct" }) else {
            throw BiliFailure(code: "LOGIN_INCOMPLETE", message: "请先完成官方登录及安全验证。")
        }
        let previous = cookies
        generation = UUID()
        let version = generation
        cookies = valid.map(StoredCookie.init)
        validatingLogin = true
        defer { if generation == version { validatingLogin = false } }
        do {
            let data = try await request("/x/web-interface/nav")
            try check(version)
            guard data["isLogin"] as? Bool == true, int(data["mid"]) > 0 else {
                throw BiliFailure(code: "-101", message: "登录尚未完成，请继续验证。")
            }
            try vault.save(cookies)
            return User.map(data)
        } catch {
            if generation == version { cookies = previous }
            throw error
        }
    }
    func ensureDevice() async throws {
        if cookies.contains(where: { $0.name == "buvid3" && $0.matches(URL(string: "https://api.bilibili.com/")!) }) {
            return
        }
        if let deviceTask {
            return try await withTaskCancellationHandler(
                operation: { try await deviceTask.value }, onCancel: { deviceTask.cancel() })
        }
        let version = generation
        let task = Task<Void, Error> {
            let data = try await self.request("/x/frontend/finger/spi")
            try self.check(version)
            guard let value = data["b_3"] as? String,
                value.range(of: "^[A-Za-z0-9_-]{10,256}$", options: .regularExpression) != nil
            else { throw BiliFailure.invalid }
            for (name, key) in [("buvid3", "b_3"), ("buvid4", "b_4")] {
                if let value = data[key] as? String,
                    let cookie = HTTPCookie(properties: [
                        .name: name, .value: value, .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
                        .expires: Date().addingTimeInterval(31_536_000),
                    ])
                {
                    self.cookies.removeAll { $0.name == name }
                    self.cookies.append(StoredCookie(cookie))
                }
            }
            if !self.validatingLogin { try self.vault.save(self.cookies) }
        }
        deviceTask = task
        defer { deviceTask = nil }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    func request(
        _ path: String, query: [String: String] = [:], form: [String: String]? = nil, wbi: Bool = false,
        referer: String = "https://www.bilibili.com/"
    ) async throws -> JSON {
        let envelope = try await envelope(path, query: query, form: form, wbi: wbi, referer: referer)
        let code = int(envelope["code"])
        guard code == 0 else {
            let text = clean(envelope["message"] ?? envelope["msg"])
            throw BiliFailure(
                code: "\(code)",
                message: code == -101 ? "登录已失效，请重新登录。" : text.isEmpty ? "B 站请求失败（\(code)）。" : "\(text)（\(code)）")
        }
        guard let data = envelope["data"] as? JSON else {
            if form != nil && (envelope["data"] == nil || envelope["data"] is NSNull) { return [:] }
            throw BiliFailure.invalid
        }
        if data["v_voucher"] != nil {
            throw BiliFailure(code: "-352", message: "B 站要求安全验证，请登录后重试（-352）。")
        }
        return data
    }
    func requestArray(_ path: String, query: [String: String]) async throws -> [JSON] {
        let value = try await envelope(path, query: query, form: nil, wbi: false, referer: "https://www.bilibili.com/")
        guard int(value["code"]) == 0 else {
            let code = int(value["code"])
            let text = clean(value["message"])
            throw BiliFailure(code: "\(code)", message: text.isEmpty ? "B 站请求失败（\(code)）。" : "\(text)（\(code)）")
        }
        if obj(value["data"])["v_voucher"] != nil {
            throw BiliFailure(code: "-352", message: "B 站要求安全验证，请登录后重试（-352）。")
        }
        guard let result = value["data"] as? [JSON] else { throw BiliFailure.invalid }
        return result
    }
    func danmakuData(_ cid: Int) async throws -> Data {
        guard cid > 0 else { throw BiliFailure.invalid }
        let version = generation
        let url = URL(string: "https://api.bilibili.com/x/v1/dm/list.so?oid=\(cid)")!
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let header = cookies.filter { $0.matches(url) }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !header.isEmpty { request.setValue(header, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation(); try check(version)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.url.map(Self.trusted) == true, data.count <= 8_000_000,
            !(response.mimeType?.contains("json") ?? false)
        else { throw BiliFailure(code: "DANMAKU_UNAVAILABLE", message: "弹幕暂时无法读取，请重试。") }
        return data
    }
    private func envelope(_ path: String, query: [String: String], form: [String: String]?, wbi: Bool, referer: String)
        async throws -> JSON
    {
        let version = generation
        guard
            var components = URLComponents(
                string: path.hasPrefix("https://") ? path : "https://api.bilibili.com\(path)")
        else { throw BiliFailure.invalid }
        var values = query
        for item in components.queryItems ?? [] { values[item.name] = item.value }
        components.query = nil
        components.percentEncodedQuery =
            wbi
            ? Self.signedQuery(values, key: try await signingKey(), timestamp: Int(Date().timeIntervalSince1970))
            : values.keys.sorted().map { "\(Self.encode($0))=\(Self.encode(values[$0]!))" }.joined(separator: "&")
        guard let url = components.url, Self.trusted(url) else { throw BiliFailure.invalid }
        var request = URLRequest(url: url)
        request.httpMethod = form == nil ? "GET" : "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        let header = cookies.filter { $0.matches(url) }.sorted { $0.path.count > $1.path.count }.map {
            "\($0.name)=\($0.value)"
        }.joined(separator: "; ")
        if !header.isEmpty { request.setValue(header, forHTTPHeaderField: "Cookie") }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form.keys.sorted().map { "\(Self.encode($0))=\(Self.encode(form[$0]!))" }.joined(
                separator: "&"
            ).data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try check(version)
        guard let response = response as? HTTPURLResponse else { throw BiliFailure.invalid }
        guard response.statusCode == 200 else {
            throw BiliFailure(
                code: "\(response.statusCode)",
                message: [412, 429].contains(response.statusCode)
                    ? "B 站暂时限制了请求，请登录或稍后重试（\(response.statusCode)）。" : "连接 B 站失败（HTTP \(response.statusCode)）。")
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
        let issued = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).map(StoredCookie.init).filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "bilibili.com" || domain.hasSuffix(".bilibili.com")
        }
        if !issued.isEmpty {
            for cookie in issued {
                cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
                cookies.append(cookie)
            }
            if !validatingLogin { try vault.save(cookies) }
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? JSON, result["code"] is NSNumber else {
            throw BiliFailure.invalid
        }
        return result
    }
    private func signingKey() async throws -> String {
        if let key, key.1 > Date() { return key.0 }
        if let keyTask { return try await keyTask.value }
        let version = generation
        let task = Task<String, Error> {
            let raw = try await self.envelope(
                "/x/web-interface/nav", query: [:], form: nil, wbi: false, referer: "https://www.bilibili.com/")
            let images = obj(obj(raw["data"])["wbi_img"])
            guard let image = secureURL(images["img_url"]), let sub = secureURL(images["sub_url"]) else {
                throw BiliFailure.invalid
            }
            let rawKey = Array(
                image.deletingPathExtension().lastPathComponent + sub.deletingPathExtension().lastPathComponent)
            guard rawKey.count == 64 else { throw BiliFailure.invalid }
            let value = String(Self.mixin.prefix(32).map { rawKey[$0] })
            try self.check(version)
            self.key = (value, Date().addingTimeInterval(600))
            return value
        }
        keyTask = task
        defer { keyTask = nil }
        return try await task.value
    }
}

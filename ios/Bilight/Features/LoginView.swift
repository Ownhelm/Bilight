import SwiftUI
import WebKit
import CoreImage.CIFilterBuiltins

@MainActor final class LoginState: ObservableObject {
    @Published var busy = false
    @Published var error: String?
    var task: Task<Void, Never>?
    func received(_ cookies: [HTTPCookie], app: AppModel) {
        guard !busy, cookies.contains(where: { $0.name == "SESSDATA" }),
            cookies.contains(where: { $0.name == "bili_jct" })
        else { return }
        busy = true
        error = nil
        task = Task {
            do { try await app.login(cookies) } catch is CancellationError {} catch {
                self.error = error.localizedDescription
            }
            if !Task.isCancelled { busy = false }
        }
    }
}
struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = LoginState()
    @State private var mode = 1
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("连接你的哔哩哔哩").font(.title3.bold())
                    Text("使用 B 站账号登录，账号仅保存在这台 iPhone。").font(.caption).foregroundStyle(Color.biliMuted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                if state.busy { ProgressView("正在验证账号").font(.footnote).padding(8) }
                if let error = state.error {
                    Text(error).font(.caption).foregroundStyle(Color.biliPink).padding(.horizontal, 20)
                }
                ContentTabs(titles: ["手机验证", "扫码登录"], selection: $mode).padding(.horizontal, 20)
                if mode == 1 {
                    DirectQRLogin { state.received($0, app: app) }
                } else {
                    OfficialLoginWebView() { state.received($0, app: app) }
                }
            }.navigationTitle("登录 B 站").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        state.task?.cancel()
                        dismiss()
                    }
                }
            }
        }.onChange(of: mode) { _, _ in state.task?.cancel(); state.busy = false; state.error = nil }
        .onDisappear { state.task?.cancel() }
    }
}
struct OfficialLoginWebView: UIViewRepresentable {
    var onCookies: ([HTTPCookie]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCookies) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
            if DemoFixtures.enabled {
                view.loadHTMLString("<meta name='viewport' content='width=device-width'><p style='font:16px system-ui;padding:24px'>离线演示无法登录账号。</p>", baseURL: nil)
                return view
            }
        #endif
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .white
        context.coordinator.store = config.websiteDataStore.httpCookieStore
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        view.load(
            URLRequest(
                url: URL(
                    string: "https://passport.bilibili.com/h5-app/passport/login")!
            ))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        coordinator.store?.remove(coordinator)
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        var store: WKHTTPCookieStore?
        var active = true
        let onCookies: ([HTTPCookie]) -> Void
        init(_ callback: @escaping ([HTTPCookie]) -> Void) { onCookies = callback }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { collect() }
        private func collect() {
            store?.getAllCookies { [weak self] cookies in
                guard let self, self.active else { return }
                self.onCookies(cookies)
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { collect() }
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            // Login may redirect home. Capture the new App-owned session before a homepage can render.
            if navigationAction.targetFrame?.isMainFrame != false {
                let hosts = ["passport.bilibili.com", "account.bilibili.com", "safecenter.bilibili.com"]
                guard url.scheme == "https", let host = url.host, hosts.contains(host) else {
                    collect()
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }
}

/// Each presentation owns an ephemeral, isolated login session. No existing cookies are imported.
struct DirectQRLogin: View {
    var onCookies: ([HTTPCookie]) -> Void
    @State private var image: UIImage?
    @State private var status = "正在获取二维码"
    @State private var error: String?
    @State private var finished = false
    @State private var generation = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("扫码，连接你的关注").font(.title2.bold())
                Text("使用另一台设备上的哔哩哔哩 App 扫一扫")
                    .font(.subheadline).foregroundStyle(Color.biliMuted).multilineTextAlignment(.center)
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(.white)
                        .shadow(color: Color.biliPink.opacity(0.10), radius: 24, y: 8)
                    if let image, !finished {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding(20)
                            .accessibilityLabel("哔哩哔哩登录二维码")
                    } else if finished {
                        Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(Color.biliMuted)
                    } else { ProgressView() }
                }.frame(width: 256, height: 256)
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.biliPink.opacity(0.12)))
                Text(status).font(.subheadline.weight(.medium)).foregroundStyle(Color.biliPink)
                    .accessibilityAddTraits(.updatesFrequently)
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if finished {
                    Button("重新获取二维码") { generation += 1 }
                        .buttonStyle(.borderedProminent).tint(Color.biliPink).frame(minHeight: 44)
                }
                Text("同一台手机登录，可切换上方「手机验证」。")
                    .font(.caption).foregroundStyle(Color.biliMuted).multilineTextAlignment(.center)
            }.padding(.horizontal, 24).padding(.vertical, 32).frame(maxWidth: .infinity)
        }.background(Color.biliPink.opacity(0.025))
            .task(id: generation) { await run() }
    }

    @MainActor private func run() async {
        image = nil; error = nil; finished = false; status = "正在获取二维码"
        #if DEBUG
        if DemoFixtures.enabled { status = "离线演示无法登录账号"; finished = true; return }
        #endif
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: BiliRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (challenge, _) = try await request("generate", session: session)
            let (value, key) = try Self.challenge(challenge)
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(value.utf8); filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                let cg = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                    from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { throw BiliFailure.invalid }
            image = UIImage(cgImage: cg); status = "等待扫码"
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(2))
                if scenePhase != .active { continue }
                let (data, cookies) = try await request("poll", key: key, session: session)
                guard let code = data["code"] as? Int else { throw BiliFailure.invalid }
                switch code {
                case 86101: status = "等待扫码"
                case 86090: status = "已扫码，请在 B 站 App 中确认"
                case 86038: status = "二维码已过期"; finished = true; return
                case 0:
                    guard cookies.contains(where: { $0.name == "SESSDATA" }),
                        cookies.contains(where: { $0.name == "bili_jct" }) else {
                        throw BiliFailure(code: "LOGIN_INCOMPLETE", message: "登录凭据不完整，请使用手机验证完成官方登录。")
                    }
                    status = "扫码成功，正在验证账号"; finished = true; onCookies(cookies); return
                default:
                    throw BiliFailure(code: "\(code)", message: "\(clean(data["message"]))（\(code)）")
                }
            }
            status = "二维码已过期"; finished = true
        } catch is CancellationError {} catch {
            guard !Task.isCancelled else { return }
            status = "二维码登录未完成"; self.error = error.localizedDescription; finished = true
        }
    }

    static func challenge(_ data: JSON) throws -> (String, String) {
        guard let value = data["url"] as? String,
            let parts = URLComponents(string: value), parts.scheme == "https",
            let host = parts.host, ["passport.bilibili.com", "account.bilibili.com"].contains(host),
            parts.user == nil, parts.password == nil, parts.port == nil,
            parts.url != nil else {
            throw BiliFailure(code: "QR_URL_INVALID", message: "B 站返回的二维码登录地址无法识别，请重新获取。")
        }
        guard let key = data["qrcode_key"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BiliFailure(code: "QR_KEY_MISSING", message: "B 站未返回二维码凭据，请重新获取。")
        }
        return (value, key)
    }

    func request(_ action: String, key: String? = nil, session: URLSession) async throws -> (JSON, [HTTPCookie]) {
        var parts = URLComponents(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/\(action)")!
        parts.queryItems = [URLQueryItem(name: "source", value: "main-fe-header")]
        if let key { parts.queryItems?.append(URLQueryItem(name: "qrcode_key", value: key)) }
        var request = URLRequest(url: parts.url!)
        request.setValue(BiliHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://passport.bilibili.com/login", forHTTPHeaderField: "Referer")
        let (bytes, raw) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = raw as? HTTPURLResponse, response.statusCode == 200,
            response.url?.host == "passport.bilibili.com", bytes.count < 1_000_000,
            let envelope = try JSONSerialization.jsonObject(with: bytes) as? JSON,
            let code = envelope["code"] as? Int else { throw BiliFailure.invalid }
        guard code == 0 else { throw BiliFailure(code: "\(code)", message: "\(clean(envelope["message"]))（\(code)）") }
        guard let data = envelope["data"] as? JSON else { throw BiliFailure.invalid }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        return (data, HTTPCookie.cookies(withResponseHeaderFields: headers, for: response.url!))
    }
}

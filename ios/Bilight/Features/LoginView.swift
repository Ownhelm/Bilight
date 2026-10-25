import SwiftUI
import WebKit

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
            busy = false
        }
    }
}
struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = LoginState()
    @State private var mode = 0
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("连接你的哔哩哔哩").font(.title3.bold())
                    Text("在官方页面完成登录和验证，账号仅保存在这台 iPhone。").font(.caption).foregroundStyle(Color.biliMuted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                if state.busy { ProgressView("正在验证账号").font(.footnote).padding(8) }
                if let error = state.error {
                    Text(error).font(.caption).foregroundStyle(Color.biliPink).padding(.horizontal, 20)
                }
                ContentTabs(titles: ["手机验证", "扫码登录"], selection: $mode).padding(.horizontal, 20)
                OfficialLoginWebView(mode: mode) { state.received($0, app: app) }.id(mode)
            }.navigationTitle("登录 B 站").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        state.task?.cancel()
                        dismiss()
                    }
                }
            }
        }.onDisappear { state.task?.cancel() }
    }
}
struct OfficialLoginWebView: UIViewRepresentable {
    var mode: Int
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
        view.customUserAgent = mode == 0 ? nil : BiliHTTP.userAgent
        if mode == 1 { view.pageZoom = min(1, UIScreen.main.bounds.width / 980) }
        view.isOpaque = false
        view.backgroundColor = .white
        context.coordinator.store = config.websiteDataStore.httpCookieStore
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        view.load(
            URLRequest(
                url: URL(
                    string: mode == 0
                        ? "https://passport.bilibili.com/h5-app/passport/login" : "https://passport.bilibili.com/login")!
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

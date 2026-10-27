package app.bilight.android.ui

import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.unit.dp
import app.bilight.android.core.AppModel
import kotlinx.coroutines.delay

@Composable fun LoginDialog(app: AppModel) {
    var loginJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    var web by remember { mutableStateOf<WebView?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var mode by remember { mutableIntStateOf(1) }
    val currentMode by rememberUpdatedState(mode)
    var active by remember { mutableStateOf(true) }
    val cookieManager = remember { CookieManager.getInstance() }
    fun close() { loginJob?.cancel(); web?.stopLoading(); app.showLogin = false }
    fun collect() {
        if (busy || !active || currentMode != 0) return
        val header = cookieManager.getCookie("https://api.bilibili.com/").orEmpty()
        if (!header.contains("SESSDATA=") || !header.contains("bili_jct=")) return
        busy = true
        loginJob = app.login(header) { success,message -> busy = false; error = message; if (success) cookieManager.removeAllCookies(null) }
    }
    Dialog(onDismissRequest=::close,properties=DialogProperties(usePlatformDefaultWidth=false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.safeDrawingPadding().imePadding()) {
                SectionTitle("登录B站",::close)
                TabRow(selectedTabIndex=mode) { listOf("手机验证","扫码登录").forEachIndexed { i,label -> Tab(selected=mode==i,onClick={ loginJob?.cancel(); busy=false; error=null; mode=i },text={ Text(label) }) } }
                if (busy) Loading("正在验证账号")
                ErrorNotice(error)
                if (mode == 1) {
                    DirectQRLogin { header ->
                        if (!busy) {
                            busy = true
                            loginJob = app.login(header) { _, message -> busy = false; error = message }
                        }
                    }
                } else key(mode) {
                    AndroidView(factory={ context ->
                        WebView(context).apply {
                            web = this
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            // This fixed-layout official form cannot follow system text zoom; pinch zoom remains available.
                            settings.textZoom = 100
                            settings.useWideViewPort = true
                            settings.loadWithOverviewMode = true
                            settings.setSupportZoom(true)
                            settings.builtInZoomControls = true
                            settings.displayZoomControls = false
                            settings.allowFileAccess = false
                            settings.allowContentAccess = false
                            settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
                            cookieManager.setAcceptCookie(true); cookieManager.setAcceptThirdPartyCookies(this,false)
                            webViewClient = object: WebViewClient() {
                                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                                    if (!request.isForMainFrame) return request.url.scheme != "https"
                                    val allowed = request.url.scheme == "https" && request.url.host in listOf("passport.bilibili.com","account.bilibili.com","safecenter.bilibili.com")
                                    if (!allowed) collect()
                                    return !allowed
                                }
                                override fun onPageFinished(view: WebView,url: String) {
                                    // Only repair spacing on the official login form; never alter consent or verification.
                                    if (android.net.Uri.parse(url).let { it.scheme=="https" && it.host=="passport.bilibili.com" && it.path=="/h5-app/passport/login" }) {
                                        view.evaluateJavascript("""(()=>{if(location.origin!=='https://passport.bilibili.com'||location.pathname!=='/h5-app/passport/login')return;const style=document.createElement('style');style.textContent='.explain-tips{position:static!important;margin:16px 16px 24px!important;width:auto!important}';document.head.appendChild(style)})()""",null)
                                    }
                                    collect()
                                }
                            }
                            // This App's transient login profile is cleared before each new official sign-in.
                            cookieManager.removeAllCookies { loadUrl("https://passport.bilibili.com/h5-app/passport/login") }
                        }
                    },modifier=Modifier.fillMaxWidth().weight(1f),onRelease={ it.stopLoading(); it.destroy() })
                }
            }
        }
    }
    LaunchedEffect(mode) { if (mode == 0) while (true) { delay(1000); collect() } }
    DisposableEffect(Unit) { onDispose { active = false; loginJob?.cancel(); web?.stopLoading(); cookieManager.removeAllCookies(null) } }
}

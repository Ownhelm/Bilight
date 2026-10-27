package app.bilight.android.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.bilight.android.core.BiliHttp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** No shared cookie jar: only the credentials issued by this QR attempt are returned. */
internal class QRLoginSession(
    private val client: OkHttpClient = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .callTimeout(20, TimeUnit.SECONDS).build()
) {
    suspend fun request(action: String, key: String? = null): Pair<JSONObject, String> = suspendCancellableCoroutine { continuation ->
        val url = "https://passport.bilibili.com/x/passport-login/web/qrcode/$action".toHttpUrl().newBuilder()
            .addQueryParameter("source", "main-fe-header").apply { key?.let { addQueryParameter("qrcode_key", it) } }.build()
        val call = client.newCall(Request.Builder().url(url).header("User-Agent", BiliHttp.USER_AGENT)
            .header("Referer", "https://passport.bilibili.com/login").build())
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(IOException("二维码连接失败，请检查网络后重试。"))
            }
            override fun onResponse(call: Call, response: Response) {
                try {
                    val result = response.use {
                        check(it.code == 200) { "二维码请求失败（HTTP ${it.code}）" }
                        val body = it.body ?: error("B站返回了空响应")
                        val source = body.source()
                        val buffer = okio.Buffer()
                        while (buffer.size <= 1_000_000) {
                            if (source.read(buffer, 8192) == -1L) break
                        }
                        check(buffer.size <= 1_000_000) { "二维码响应过大" }
                        val envelope = JSONObject(buffer.readUtf8())
                        val code = envelope.getInt("code")
                        check(code == 0) { "${envelope.optString("message", "B站请求失败")}（$code）" }
                        val header = Cookie.parseAll(url, it.headers)
                            .filter { cookie -> cookie.matches("https://api.bilibili.com/".toHttpUrl()) }
                            .joinToString("; ") { cookie -> "${cookie.name}=${cookie.value}" }
                        envelope.getJSONObject("data") to header
                    }
                    if (continuation.isActive) continuation.resume(result)
                } catch (e: Exception) {
                    if (continuation.isActive) continuation.resumeWithException(e)
                }
            }
        })
    }
    // TLS close can write to the socket. Finish cleanup off the UI thread, including on cancellation.
    suspend fun close() = withContext(NonCancellable+Dispatchers.IO) {
        client.dispatcher.cancelAll(); client.connectionPool.evictAll(); client.dispatcher.executorService.shutdown()
    }
}

internal fun qrLoginChallenge(data: JSONObject): Pair<String, String> {
    val value = data.optString("url")
    val url = try { java.net.URI(value) } catch (_: Exception) { null }
    check(url != null && url.scheme == "https" &&
        url.host in setOf("passport.bilibili.com", "account.bilibili.com") &&
        url.rawUserInfo == null && url.port == -1) { "B站返回的二维码登录地址无法识别，请重新获取。" }
    val key = data.optString("qrcode_key")
    check(key.isNotBlank()) { "B站未返回二维码凭据，请重新获取。" }
    return value to key
}

@Composable internal fun DirectQRLogin(onCookies: (String) -> Unit) {
    var generation by remember { mutableIntStateOf(0) }
    var bitmap by remember { mutableStateOf<Bitmap?>(null) }
    var status by remember { mutableStateOf("正在获取二维码") }
    var error by remember { mutableStateOf<String?>(null) }
    var finished by remember { mutableStateOf(false) }
    val callback by rememberUpdatedState(onCookies)
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    val pink = Pink
    LaunchedEffect(generation) {
        bitmap = null; error = null; finished = false; status = "正在获取二维码"
        val session = QRLoginSession()
        try {
            val challenge = session.request("generate").first
            val (value, key) = qrLoginChallenge(challenge)
            bitmap = withContext(Dispatchers.Default) {
                val matrix = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, 720, 720, mapOf(EncodeHintType.MARGIN to 4))
                val pixels = IntArray(matrix.width * matrix.height) { index ->
                    if (matrix[index % matrix.width, index / matrix.width]) android.graphics.Color.rgb(32, 33, 40) else android.graphics.Color.WHITE
                }
                Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
            }
            status = "等待扫码"
            val deadline = android.os.SystemClock.elapsedRealtime() + 180_000
            while (android.os.SystemClock.elapsedRealtime() < deadline) {
                delay(2200)
                if (!lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) continue
                val (data, header) = session.request("poll", key)
                when (val code = data.getInt("code")) {
                    86101 -> status = "等待扫码"
                    86090 -> status = "已扫码，请在 B 站 App 中确认"
                    86038 -> { status = "二维码已过期"; finished = true; return@LaunchedEffect }
                    0 -> {
                        check(header.split(';').any { it.trim().startsWith("SESSDATA=") } &&
                            header.split(';').any { it.trim().startsWith("bili_jct=") }) {
                            "登录凭据不完整，请使用手机验证完成官方登录。"
                        }
                        status = "扫码成功，正在验证账号"; finished = true; callback(header); return@LaunchedEffect
                    }
                    else -> kotlin.error("${data.optString("message", "二维码登录失败")}（$code）")
                }
            }
            status = "二维码已过期"; finished = true
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { status = "二维码登录未完成"; error = e.message; finished = true }
        finally { session.close() }
    }
    Column(Modifier.fillMaxSize().background(pink.copy(alpha = 0.025f)).verticalScroll(rememberScrollState())
        .padding(horizontal = 24.dp, vertical = 32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("扫码，连接你的关注", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        Text("使用另一台设备上的哔哩哔哩 App 扫一扫", color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        Surface(Modifier.size(256.dp), shape = RoundedCornerShape(24.dp), color = Color.White,
            shadowElevation = 4.dp, border = androidx.compose.foundation.BorderStroke(1.dp, pink.copy(alpha = 0.15f))) {
            Box(contentAlignment = Alignment.Center) {
                val qr = bitmap
                if (qr != null && !finished) Image(qr.asImageBitmap(), "哔哩哔哩登录二维码", Modifier.fillMaxSize().padding(12.dp))
                else if (finished) Text(status, Modifier.padding(24.dp), textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                else CircularProgressIndicator(color = pink)
            }
        }
        Text(status, color = pink, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
        error?.let { Text(it, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center) }
        if (finished) Button(onClick = { generation++ }, colors = ButtonDefaults.buttonColors(containerColor = pink)) { Text("重新获取二维码") }
        Text("同一台手机登录，可切换上方「手机验证」。", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}

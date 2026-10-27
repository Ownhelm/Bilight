package app.bilight.android.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class BiliHttp(private val vault: SecureStore, val client: OkHttpClient = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(20,TimeUnit.SECONDS).callTimeout(30,TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()) {
    companion object {
        const val USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        private val mixin = intArrayOf(46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52)
        fun trusted(url: HttpUrl): Boolean = url.isHttps && url.port == 443 && url.username.isEmpty() && url.password.isEmpty() && (url.host == "bilibili.com" || url.host.endsWith(".bilibili.com"))
        fun encode(value: String): String = java.net.URLEncoder.encode(value, "UTF-8").replace("+", "%20").replace("*", "%2A").replace("%7E", "~")
        fun signedQuery(query: Map<String,String>, key: String, timestamp: Long): String {
            val values = (query - "w_rid") + ("wts" to timestamp.toString())
            val text = values.toSortedMap().entries.joinToString("&") { "${encode(it.key)}=${encode(it.value.replace(Regex("[!'()*]"), ""))}" }
            val digest = MessageDigest.getInstance("MD5").digest((text + key).toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
            return "$text&w_rid=$digest"
        }
    }
    private val lock = Any()
    private var cookies = emptyList<Cookie>()
    private var cookieRevision = 0L
    private var savedCookieRevision = -1L
    private val calls = mutableSetOf<Call>()
    @Volatile var generation = 0L; private set
    @Volatile var user: User? = null; private set
    @Volatile private var verified = false
    @Volatile private var authChanging = false
    private val persistenceMutex = Mutex()
    private val verificationMutex = Mutex()
    private var signingKey: Pair<String,Long>? = null
    private val signingMutex = Mutex()
    private val deviceMutex = Mutex()
    private val loginMutex = Mutex()
    fun check(version: Long) { if (version != generation) throw BiliFailure("ACCOUNT_CHANGED", "账号已变化，请重新打开页面。") }
    fun csrf(): String = synchronized(lock) {
        if (authChanging) throw BiliFailure("ACCOUNT_CHANGED", "正在验证账号，请稍候。")
        if (user == null || cookies.none { it.name == "SESSDATA" && it.expiresAt > System.currentTimeMillis() }) throw BiliFailure("-101", "请先登录B站账号。")
        cookies.firstOrNull { it.name == "bili_jct" && it.expiresAt > System.currentTimeMillis() }?.value ?: throw BiliFailure("-101", "登录已失效，请重新登录。")
    }
    private suspend fun persist(version: Long = generation) = persistenceMutex.withLock {
        val (revision,bytes) = synchronized(lock) {
            check(version)
            cookieRevision to JSONObject().put("cookies",JSONArray(cookies.map { it.toString() })).put("user",user?.let { JSONObject().put("mid",it.mid).put("name",it.name).put("face",it.avatar) }).toString().toByteArray()
        }
        withContext(Dispatchers.IO) { check(version); vault.save(bytes) }
        synchronized(lock) { check(version); savedCookieRevision=revision }
    }
    private suspend fun persistIssuedCookies() {
        if (user!=null && !authChanging && synchronized(lock) { cookieRevision!=savedCookieRevision }) persist()
    }
    suspend fun restore(): User? {
        val version=generation
        val loaded = withContext(Dispatchers.IO) { vault.load() }
        check(version)
        if (loaded != null) {
            val text=String(loaded)
            val saved=if (text.trimStart().startsWith('{')) JSONObject(text) else null
            val raw = saved?.optJSONArray("cookies") ?: JSONArray(text)
            synchronized(lock) {
                check(version)
                cookies = (0 until raw.length()).mapNotNull { Cookie.parse("https://api.bilibili.com/".toHttpUrl(), raw.getString(it)) }.filter { it.expiresAt > System.currentTimeMillis() }; savedCookieRevision=cookieRevision
                user=saved?.optJSONObject("user")?.let(User::parse)?.takeIf { it.mid>0 }
            }
        }
        synchronized(lock) { check(version); if (cookies.none { it.name == "SESSDATA" }) { user=null; return null } }
        return try {
            val value=currentUser()
            synchronized(lock) { check(version); user=value; verified=value!=null }
            persist(version); check(version); value
        } catch (e: BiliFailure) { check(version); if (e.code=="NETWORK" && user!=null) user else throw e }
    }
    suspend fun ensureAccount(): Long = verificationMutex.withLock {
        if (authChanging) throw BiliFailure("ACCOUNT_CHANGED", "正在验证账号，请稍候。")
        if (!verified) {
            val before=generation; val value=currentUser(); check(before)
            if (value==null) { logout(); throw BiliFailure("-101","登录已失效，请重新登录。") }
            if (user!=null && user?.mid!=value.mid) { logout(); throw BiliFailure("ACCOUNT_CHANGED","账号已变化，请重新登录。") }
            user=value; verified=true; persist()
        }
        csrf(); user?.mid ?: throw BiliFailure("-101","请先登录B站账号。")
    }
    suspend fun currentUser(): User? {
        val raw = envelope("/x/web-interface/nav")
        if (raw.optInt("code") == -101) return null
        requireSuccess(raw)
        return raw.obj("data").takeIf { it.optBoolean("isLogin") && it.optLong("mid") > 0 }?.let(User::parse)
    }
    suspend fun acceptLogin(header: String): User = loginMutex.withLock {
        val names = setOf("SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid", "buvid3", "buvid4")
        val candidates = header.split(';').mapNotNull { part ->
            val i = part.indexOf('='); if (i <= 0) return@mapNotNull null
            val name = part.substring(0,i).trim(); if (name !in names) return@mapNotNull null
            Cookie.parse("https://api.bilibili.com/".toHttpUrl(), "$name=${part.substring(i+1).trim()}; Domain=.bilibili.com; Path=/; Secure; Max-Age=15552000")
        }
        if (candidates.none { it.name == "SESSDATA" } || candidates.none { it.name == "bili_jct" }) throw BiliFailure("LOGIN_INCOMPLETE", "请先完成官方登录和安全验证。")
        val old = synchronized(lock) { cookies }; val oldUser=user; val oldVerified=verified
        authChanging=true; invalidateCalls()
        val attempt=generation
        synchronized(lock) { cookies = candidates; cookieRevision++ }
        try {
            val value = currentUser() ?: throw BiliFailure("-101", "登录尚未完成，请继续验证。")
            synchronized(lock) { check(attempt); user=value; verified=true }
            persist(attempt); check(attempt); value
        } catch (e: Exception) { if (generation==attempt) { synchronized(lock) { cookies = old; cookieRevision++ }; user=oldUser; verified=oldVerified }; throw e }
        finally { authChanging=false }
    }
    private fun invalidateCalls() = synchronized(lock) { generation++; calls.forEach(Call::cancel); calls.clear(); signingKey = null }
    suspend fun logout() { invalidateCalls(); synchronized(lock) { cookies = emptyList(); user = null; verified=false }; persistenceMutex.withLock { withContext(Dispatchers.IO) { vault.clear() } } }
    suspend fun ensureDevice() = deviceMutex.withLock {
        if (synchronized(lock) { cookies.any { it.name == "buvid3" && it.expiresAt > System.currentTimeMillis() } }) return@withLock
        val data = request("/x/frontend/finger/spi")
        val issued = listOf("buvid3" to "b_3", "buvid4" to "b_4").mapNotNull { (name,field) -> data.text(field).takeIf { Regex("^[A-Za-z0-9_-]{10,256}$").matches(it) }?.let { Cookie.Builder().name(name).value(it).domain("bilibili.com").path("/").secure().expiresAt(System.currentTimeMillis()+31536000000).build() } }
        if (issued.none { it.name == "buvid3" }) invalid("B站访客标识暂时无法读取。")
        synchronized(lock) { cookies = cookies.filter { c -> issued.none { it.name == c.name } } + issued; cookieRevision++ }
        if (user != null && !authChanging) persist()
    }
    suspend fun request(path: String, query: Map<String,String> = emptyMap(), form: Map<String,String>? = null, wbi: Boolean = false, referer: String = "https://www.bilibili.com/"): JSONObject {
        val raw = envelope(path,query,form,wbi,referer); requireSuccess(raw)
        if (form != null && raw.isNull("data")) return JSONObject()
        val data = raw.optJSONObject("data") ?: invalid()
        if (data.has("v_voucher")) throw BiliFailure("-352", "B站要求安全验证，请登录后重试（-352）。")
        return data
    }
    suspend fun array(path: String, query: Map<String,String>): List<JSONObject> {
        val raw = envelope(path,query); requireSuccess(raw); return raw.optJSONArray("data")?.objects() ?: invalid()
    }
    private fun requireSuccess(raw: JSONObject) {
        if (!raw.has("code")) invalid()
        val code = raw.getInt("code")
        if (code != 0) throw BiliFailure(code.toString(), if (code == -101) "登录已失效，请重新登录。" else "${raw.text("message", raw.text("msg", "B站请求失败"))}（$code）")
    }
    private suspend fun wbiKey(): String = signingMutex.withLock {
        signingKey?.takeIf { it.second > System.currentTimeMillis() }?.let { return@withLock it.first }
        val data = envelope("/x/web-interface/nav").obj("data").obj("wbi_img")
        val raw = listOf("img_url", "sub_url").joinToString("") { data.text(it).substringAfterLast('/').substringBefore('.') }
        if (raw.length != 64) invalid("签名参数暂时无法读取。")
        mixin.take(32).map { raw[it] }.joinToString("").also { signingKey = it to System.currentTimeMillis()+600000 }
    }
    private suspend fun envelope(path: String, query: Map<String,String> = emptyMap(), form: Map<String,String>? = null, wbi: Boolean = false, referer: String = "https://www.bilibili.com/"): JSONObject {
        val version = generation
        val base = (if (path.startsWith("https://")) path else "https://api.bilibili.com$path").toHttpUrl()
        if (!trusted(base)) invalid("请求地址不受信任。")
        val encoded = if (wbi) signedQuery(query,wbiKey(),System.currentTimeMillis()/1000) else query.toSortedMap().entries.joinToString("&") { "${encode(it.key)}=${encode(it.value)}" }
        val url = base.newBuilder().encodedQuery(encoded.takeIf(String::isNotEmpty)).build()
        val request = Request.Builder().url(url).header("User-Agent", USER_AGENT).header("Referer", referer).header("Origin", "https://www.bilibili.com")
        val header = synchronized(lock) { cookies.filter { it.matches(url) && it.expiresAt > System.currentTimeMillis() }.sortedByDescending { it.path.length }.joinToString("; ") { "${it.name}=${it.value}" } }
        if (header.isNotEmpty()) request.header("Cookie",header)
        if (form != null) request.post(FormBody.Builder().apply { form.forEach { (k,v) -> add(k,v) } }.build())
        val bytes = execute(request.build(), version)
        check(version)
        persistIssuedCookies()
        val result=withContext(Dispatchers.Default) { try { JSONObject(String(bytes)) } catch (_: Exception) { invalid() } }
        check(version); return result
    }
    suspend fun bytes(url: String, limit: Long = 8000000): ByteArray {
        val source = url.toHttpUrl(); if (!trusted(source) && mediaUrl(url) == null) invalid("资源地址不受信任。")
        val request=Request.Builder().url(source).header("User-Agent",USER_AGENT).header("Referer","https://www.bilibili.com/")
        if (trusted(source)) {
            val header=synchronized(lock) { cookies.filter { it.matches(source) && it.expiresAt>System.currentTimeMillis() }.joinToString("; ") { "${it.name}=${it.value}" } }
            if (header.isNotEmpty()) request.header("Cookie",header)
        }
        return execute(request.build(),generation,limit).also { persistIssuedCookies() }
    }
    private suspend fun execute(request: Request, version: Long, limit: Long = 8000000): ByteArray = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request)
        synchronized(lock) { check(version); calls.add(call) }
        continuation.invokeOnCancellation { call.cancel(); synchronized(lock) { calls.remove(call) } }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                synchronized(lock) { calls.remove(call) }
                val message=when (e) { is java.net.UnknownHostException -> "无法解析B站地址，请检查网络。"; is javax.net.ssl.SSLException -> "安全连接验证失败，请检查网络和系统时间。"; is java.net.SocketTimeoutException -> "连接B站超时，请重试。"; else -> "连接B站中断，请重试。" }
                if (continuation.isActive) continuation.resumeWithException(BiliFailure("NETWORK", message))
            }
            override fun onResponse(call: Call, response: Response) {
                try {
                    val bytes = response.use { r ->
                        check(version)
                        if (!r.isSuccessful) throw BiliFailure(r.code.toString(), if (r.code in listOf(412,429)) "B站暂时限制了请求，请登录或稍后重试（${r.code}）。" else "连接失败（HTTP ${r.code}）。")
                        val body = r.body ?: invalid(); if (body.contentLength() > limit) invalid("资源超过大小限制。")
                        val source = body.source(); val buffer = okio.Buffer(); var total = 0L
                        while (true) { val n = source.read(buffer,minOf(65536,limit+1-total)); if (n == -1L) break; total += n; if (total > limit) invalid("资源超过大小限制。") }
                        if (trusted(r.request.url)) {
                            val issued = Cookie.parseAll(r.request.url,r.headers).filter { it.domain == "bilibili.com" || it.domain.endsWith(".bilibili.com") }
                            if (issued.isNotEmpty()) synchronized(lock) {
                                check(version)
                                val next=cookies.filter { c -> issued.none { it.name == c.name && it.domain == c.domain && it.path == c.path } }+issued
                                if (next!=cookies) { cookies=next; cookieRevision++ }
                            }
                        }
                        buffer.readByteArray()
                    }
                    if (continuation.isActive) continuation.resume(bytes)
                } catch (e: Exception) { if (continuation.isActive) continuation.resumeWithException(e) }
                finally { synchronized(lock) { calls.remove(call) } }
            }
        })
    }
}

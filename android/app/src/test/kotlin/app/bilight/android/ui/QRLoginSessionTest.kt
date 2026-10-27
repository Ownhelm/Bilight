package app.bilight.android.ui

import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class QRLoginSessionTest {
    @Test fun acceptsBothOfficialQRCodeHosts() {
        for (host in listOf("account.bilibili.com", "passport.bilibili.com")) {
            val url = "https://$host/h5-app/passport/login/scan?key=isolated-test-key"
            assertEquals(url to "isolated-test-key", qrLoginChallenge(org.json.JSONObject()
                .put("url", url).put("qrcode_key", "isolated-test-key")))
        }
    }
    @Test fun rejectsUnsafeQRCodeHosts() {
        for (url in listOf("http://account.bilibili.com/scan", "https://account.bilibili.com.evil.example/scan",
            "https://evil.example/scan", "https://user@account.bilibili.com/scan", "https://account.bilibili.com:8443/scan")) {
            assertThrows(IllegalStateException::class.java) {
                qrLoginChallenge(org.json.JSONObject().put("url", url).put("qrcode_key", "test"))
            }
        }
        assertThrows(IllegalStateException::class.java) {
            qrLoginChallenge(org.json.JSONObject().put("url", "https://account.bilibili.com/scan"))
        }
    }

    @Test fun waitingStateDoesNotImportCookies() = runBlocking {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            assertNull(chain.request().header("Cookie"))
            assertEquals("passport.bilibili.com", chain.request().url.host)
            assertEquals("isolated-test-key", chain.request().url.queryParameter("qrcode_key"))
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body("""{"code":0,"data":{"code":86101}}""".toResponseBody("application/json".toMediaType())).build()
        }.build()
        val session = QRLoginSession(client)
        try {
            val (data, cookies) = session.request("poll", "isolated-test-key")
            assertEquals(86101, data.getInt("code")); assertEquals("", cookies)
        } finally { session.close() }
    }

    @Test fun upstreamErrorIsNotTreatedAsEmptySuccess() = runBlocking {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body("""{"code":-412,"message":"请求被拦截"}""".toResponseBody("application/json".toMediaType())).build()
        }.build()
        val session = QRLoginSession(client)
        try {
            try { session.request("generate"); fail("Expected upstream error") }
            catch (e: IllegalStateException) { assertTrue(e.message.orEmpty().contains("-412")) }
        } finally { session.close() }
    }
}

package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

class WatchLaterTest {
    private fun entry(aid: Long = 7L) = JSONObject().put("aid", aid).put("bvid", "BV12qnt6VEM1")
        .put("title", "隔离测试").put("duration", 90).put("cid", 24).put("progress", 31)

    @Test fun keepsRealCidAndProgressAndIgnoresSplitMarker() {
        val data = JSONObject().put("count", 21).put("list", JSONArray().put(entry(-1)).put(entry()))
        val result = parseWatchLaterPage(data, 1)
        assertTrue(result.more)
        assertEquals(listOf(7L), result.items.map { it.aid })
        assertEquals(Route.Watch("BV12qnt6VEM1", progress = 31, cid = 24), result.items.single().route)
        assertFalse(parseWatchLaterPage(data, 2).more)
    }

    @Test fun emptyPagesRequireAuthoritativeCountAndInvalidItemsStayRemovable() {
        val nonexistent = JSONObject().put("count", 21).put("list", JSONArray().put(entry(-1)))
        assertThrows(BiliFailure::class.java) { parseWatchLaterPage(nonexistent, 2) }
        assertThrows(BiliFailure::class.java) { parseWatchLaterPage(JSONObject().put("count", 0), 1) }
        val empty = JSONObject().put("count", 0).put("list", JSONObject.NULL)
        assertTrue(parseWatchLaterPage(empty, 1).items.isEmpty())
        val invalidVideo = JSONObject().put("count", 1).put("list", JSONArray().put(entry().put("state", -1)))
        val item = parseWatchLaterPage(invalidVideo, 1).items.single()
        assertEquals(7L, item.aid)
        assertNull(item.route)
    }

    @Test fun delegatesReadsAndSingleAndBulkWritesToTheAccountEndpoints() = runBlocking {
        val requests = CopyOnWriteArrayList<RecordedRequest>()
        MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val data = when (request.requestUrl!!.encodedPath) {
                        "/x/web-interface/nav" -> JSONObject().put("isLogin", true).put("mid", 42).put("uname", "隔离测试")
                        "/x/v2/history/toview/web" -> JSONObject().put("count", 41).put("list", JSONArray().put(entry()))
                        "/x/v2/history/toview/add", "/x/v2/history/toview/del", "/x/v2/history/toview/v2/dels" -> JSONObject()
                        else -> return MockResponse().setResponseCode(404)
                    }
                    if (request.requestUrl!!.encodedPath.startsWith("/x/v2/history/toview/")) requests += request
                    return MockResponse().setBody(JSONObject().put("code", 0).put("data", data).toString())
                }
            }
            server.start()
            val client = OkHttpClient.Builder().addInterceptor { chain ->
                val original = chain.request()
                val local = server.url(original.url.encodedPath).newBuilder().encodedQuery(original.url.encodedQuery).build()
                chain.proceed(original.newBuilder().url(local).build()).newBuilder().request(original).build()
            }.build()
            val http = BiliHttp(object : SecureStore {
                override fun load(): ByteArray? = null
                override fun save(bytes: ByteArray) {}
                override fun clear() {}
            }, client)
            http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only")
            val repository = BiliRepository(http)
            val version = http.generation
            assertTrue(repository.watchLaterPage(2, version).more)
            repository.writeWatchLater(setOf(7), true, version)
            repository.writeWatchLater(setOf(7), false, version)
            repository.writeWatchLater(linkedSetOf(7, 9), false, version, bulk = true)
            assertEquals(listOf("GET", "POST", "POST", "POST"), requests.map { it.method })
            assertEquals(listOf("web", "add", "del", "v2/dels"), requests.map { it.requestUrl!!.encodedPath.substringAfter("/toview/") })
            assertEquals(mapOf("pn" to "2", "ps" to "20", "asc" to "0", "viewed" to "0", "need_split" to "1"),
                requests.first().requestUrl!!.let { url -> url.queryParameterNames.associateWith { url.queryParameter(it) } })
            for (single in requests.subList(1, 3)) {
                assertEquals("application/x-www-form-urlencoded", single.getHeader("Content-Type"))
                assertEquals("aid=7&csrf=test-only", single.body.readUtf8())
            }
            val bulk = requests.last()
            val contentType = bulk.getHeader("Content-Type").orEmpty()
            assertTrue(contentType.startsWith("multipart/form-data; boundary="))
            val boundary = contentType.substringAfter("boundary=")
            val parts = bulk.body.readUtf8().split("--$boundary").filter { it.contains("Content-Disposition") }
            assertEquals(2, parts.size)
            assertTrue(parts.any { it.contains("name=\"resources\"") && it.endsWith("\r\n\r\n7,9\r\n") })
            assertTrue(parts.any { it.contains("name=\"csrf\"") && it.endsWith("\r\n\r\ntest-only\r\n") })
        }
    }
}

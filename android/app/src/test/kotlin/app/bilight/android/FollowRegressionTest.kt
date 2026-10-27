package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class FollowRegressionTest {
    @Test fun retryUsesTheOriginalClickedTargetInsteadOfTogglingTheFreshServerState() = runBlocking {
        var following=false; var writes=0; var fail=true
        val server=MockWebServer()
        server.dispatcher=object: Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val data=when (request.requestUrl!!.encodedPath) {
                    "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",42).put("uname","隔离测试")
                    "/x/frontend/finger/spi" -> JSONObject().put("b_3","FIXTURE-ISSUED-DEVICE-1234").put("b_4","FIXTURE-ISSUED-DEVICE-5678")
                    "/x/relation" -> JSONObject().put("attribute",if (following) 2 else 0)
                    "/x/relation/modify" -> { writes++; following=request.body.readUtf8().split('&').contains("act=1"); if (fail) return MockResponse().setResponseCode(503); JSONObject() }
                    else -> return MockResponse().setResponseCode(404)
                }
                return MockResponse().setBody(JSONObject().put("code",0).put("data",data).toString())
            }
        }; server.start()
        try {
            val store=object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} }
            val client=OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain -> val original=chain.request(); val local=server.url(original.url.encodedPath).newBuilder().encodedQuery(original.url.encodedQuery).build(); chain.proceed(original.newBuilder().url(local).build()).newBuilder().request(original).build() }.build()
            val http=BiliHttp(store,client); http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only")
            val repository=BiliRepository(http)
            // The UI still shows + after a lost response, so its intended target remains following=true.
            try { repository.follow(1,true); fail("Response loss must not look successful") } catch (_: BiliFailure) { }
            assertTrue(following); assertEquals(1,writes)
            fail=false; assertTrue(repository.follow(1,true).following); assertEquals(1,writes)
            assertFalse(repository.follow(1,false).following); assertEquals(2,writes)
        } finally { server.shutdown() }
    }
}

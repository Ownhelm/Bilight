package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PeopleRepositoryTest {
    @Test fun realFollowingWithoutANameCannotBlockTheRestOfThePage() = runBlocking {
        val server=MockWebServer(); server.start()
        try {
            server.dispatcher=object: Dispatcher() {
                override fun dispatch(request: RecordedRequest)=MockResponse().setBody(when(request.requestUrl!!.encodedPath) {
                    "/x/web-interface/nav" -> """{"code":0,"data":{"isLogin":true,"mid":42,"uname":"隔离账号"}}"""
                    "/x/relation/followings" -> """{"code":0,"data":{"total":2,"list":[{"mid":7,"uname":"影视飓风","attribute":2},{"mid":8,"uname":"","attribute":2}]}}"""
                    else -> error("Unexpected request")
                })
            }
            val client=OkHttpClient.Builder().addInterceptor { chain ->
                val original=chain.request()
                chain.proceed(original.newBuilder().url(server.url(original.url.encodedPath).newBuilder().encodedQuery(original.url.encodedQuery).build()).build()).newBuilder().request(original).build()
            }.build()
            val memory=object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} }
            val http=BiliHttp(memory,client); http.acceptLogin("SESSDATA=fixture-only; bili_jct=fixture-only")
            val result=BiliRepository(http).people(1,false)
            assertEquals(listOf(7L,8L),result.items.map { it.mid })
            assertEquals("UP主 8",result.items[1].name)
            assertFalse(result.more)
        } finally { server.shutdown() }
    }
}

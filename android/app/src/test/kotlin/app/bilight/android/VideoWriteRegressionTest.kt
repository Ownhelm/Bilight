package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URLDecoder

class VideoWriteRegressionTest {
    private val detail=Detail(Video("BV1NGZtBwELa",42,"隔离测试",null,120,0,User(1,"演示",null),0),listOf(Part(1,1,"P1",120)),"",2,Statistics(0,0,0))
    private class Platform: Dispatcher() {
        var liked=false; var coins=0; var favorite=setOf(1L); var failWrite=false
        val forms=mutableListOf<Pair<String,Map<String,String>>>()
        override fun dispatch(request: RecordedRequest): MockResponse {
            val path=request.requestUrl!!.encodedPath
            var data: JSONObject?=null
            when (path) {
                "/x/web-interface/nav" -> data=JSONObject().put("isLogin",true).put("mid",42).put("uname","隔离测试")
                "/x/frontend/finger/spi" -> data=JSONObject().put("b_3","FIXTURE-BILIGHT-DEVICE-1234").put("b_4","FIXTURE-BILIGHT-DEVICE-5678")
                "/x/web-interface/archive/relation" -> data=JSONObject().put("like",liked).put("coin",coins).put("favorite",favorite.isNotEmpty())
                "/x/v3/fav/folder/created/list-all" -> data=JSONObject().put("count",2).put("list",JSONArray((1L..2L).map { id -> JSONObject().put("id",id).put("mid",42).put("title","演示$id").put("media_count",1).put("fav_state",if (id in favorite) 1 else 0).put("max_count",100) }))
                else -> {
                    val form=request.body.readUtf8().split('&').associate { part -> part.substringBefore('=') to URLDecoder.decode(part.substringAfter('='),"UTF-8") }
                    forms += path to form
                    when (path) {
                        "/x/web-interface/archive/like" -> liked=form["like"]=="1"
                        "/x/web-interface/coin/add" -> { coins+=form["multiply"]!!.toInt(); if (form["select_like"]=="1") liked=true }
                        "/x/web-interface/archive/like/triple" -> { liked=true; coins=maxOf(1,coins); favorite=if (favorite.isEmpty()) setOf(1) else favorite }
                        "/x/v3/fav/resource/deal" -> { favorite=favorite-form["del_media_ids"].orEmpty().split(',').mapNotNull(String::toLongOrNull).toSet()+form["add_media_ids"].orEmpty().split(',').mapNotNull(String::toLongOrNull) }
                        else -> return MockResponse().setResponseCode(404)
                    }
                    if (failWrite) return MockResponse().setResponseCode(503)
                }
            }
            return MockResponse().setBody(JSONObject().put("code",0).put("data",data).toString())
        }
    }
    private suspend fun fixture(test: suspend (BiliRepository,Platform) -> Unit) {
        val platform=Platform(); val server=MockWebServer(); server.dispatcher=platform; server.start()
        try {
            val store=object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} }
            val client=OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain -> val original=chain.request(); val url=server.url(original.url.encodedPath).newBuilder().encodedQuery(original.url.encodedQuery).build(); chain.proceed(original.newBuilder().url(url).build()).newBuilder().request(original).build() }.build()
            val http=BiliHttp(store,client); http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only"); test(BiliRepository(http),platform)
        } finally { server.shutdown() }
    }
    @Test fun simultaneousSameLikeIsWrittenOnlyOnce() = runBlocking { fixture { repository,platform ->
        coroutineScope { List(2) { async { repository.write(detail,VideoWrite.Like(true)) } }.awaitAll() }
        assertTrue(platform.liked); assertEquals(1,platform.forms.count { it.first.endsWith("/like") })
    } }
    @Test fun coinUsesRemainingDifferenceAndDoesNotRepeatAnAlreadyReachedTarget() = runBlocking { fixture { repository,platform ->
        platform.coins=1; repository.write(detail,VideoWrite.Coin(2,true)); repository.write(detail,VideoWrite.Coin(2,true))
        val forms=platform.forms.filter { it.first.endsWith("/coin/add") }; assertEquals(1,forms.size); assertEquals("1",forms.single().second["multiply"]); assertEquals(2,platform.coins); assertTrue(platform.liked)
    } }
    @Test fun favoritesSubmitOnlyChangesAndCanRemoveAll() = runBlocking { fixture { repository,platform ->
        repository.write(detail,VideoWrite.Favorite(setOf(1))); assertTrue(platform.forms.isEmpty())
        repository.write(detail,VideoWrite.Favorite(setOf(2))); val changed=platform.forms.last().second
        assertEquals("2",changed["add_media_ids"]); assertEquals("1",changed["del_media_ids"])
        repository.write(detail,VideoWrite.Favorite(emptySet())); assertTrue(platform.favorite.isEmpty())
    } }
    @Test fun uncertainWriteIsNeverRetriedUntilAnExplicitFreshRead() = runBlocking { fixture { repository,platform ->
        platform.failWrite=true
        repeat(2) { try { repository.write(detail,VideoWrite.Like(true)); fail() } catch (e: BiliFailure) { assertEquals("WRITE_UNCERTAIN",e.code) } }
        assertEquals(1,platform.forms.size)
        platform.failWrite=false; repository.engagement(detail.video.bvid,true); repository.write(detail,VideoWrite.Like(true))
        assertEquals(1,platform.forms.size)
    } }
}

package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class FollowingPaginationTest {
    private fun post(id: String,mid: Long=7)=JSONObject().put("id_str",id).put("type","DYNAMIC_TYPE_WORD")
        .put("modules",JSONObject().put("module_author",JSONObject().put("mid",mid).put("name","隔离测试"))
            .put("module_dynamic",JSONObject().put("desc",JSONObject().put("text","分页测试动态"))))
    private fun page(flag: Any,offset: String,items: JSONArray?=JSONArray().put(post("101")))=JSONObject().put("has_more",flag).put("offset",offset).apply { if(items!=null) put("items",items) }
    private fun fixture(pages: (String?) -> JSONObject,test: suspend (BiliRepository,MutableList<String?>) -> Unit)=runBlocking {
        val offsets=java.util.Collections.synchronizedList(mutableListOf<String?>())
        val server=MockWebServer()
        server.dispatcher=object: Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val data=when(request.requestUrl!!.encodedPath) {
                    "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",42).put("uname","隔离测试")
                    "/x/frontend/finger/spi" -> JSONObject().put("b_3","FIXTURE-ISSUED-DEVICE-1234").put("b_4","FIXTURE-ISSUED-DEVICE-5678")
                    "/x/polymer/web-dynamic/v1/feed/all" -> request.requestUrl!!.queryParameter("offset").let { offsets+=it; pages(it) }
                    "/x/relation/relations" -> JSONObject().put("7",JSONObject().put("attribute",2)).put("8",JSONObject().put("attribute",0))
                    else -> return MockResponse().setResponseCode(404)
                }
                return MockResponse().setBody(JSONObject().put("code",0).put("data",data).toString())
            }
        }
        server.start()
        try {
            val client=OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val original=chain.request();val local=server.url(original.url.encodedPath).newBuilder().encodedQuery(original.url.encodedQuery).build()
                chain.proceed(original.newBuilder().url(local).build()).newBuilder().request(original).build()
            }.build()
            val http=BiliHttp(object: SecureStore { override fun load(): ByteArray?=null;override fun save(bytes: ByteArray) {};override fun clear() {} },client)
            http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only")
            test(BiliRepository(http),offsets)
        } finally { server.shutdown() }
    }
    @Test fun booleanHasMorePreservesTheCursorAndReadsTheNextPage() = fixture({ offset ->
        if(offset==null) page(true,"older-page") else page(false,"",JSONArray().put(post("102")))
    }) { repository,offsets ->
        val first=repository.following(null)
        assertTrue("A true has_more flag incorrectly ended the feed",first.more);assertEquals("older-page",first.cursor)
        val second=repository.following(first.cursor)
        assertEquals(listOf("102"),second.items.map { it.id });assertFalse(second.more)
        assertEquals(listOf(null,"older-page"),offsets.toList())
    }
    @Test fun numericFlagsRemainCompatible() = fixture({ offset -> if(offset==null) page(1,"older-page") else page(0,"") }) { repository,_ ->
        val first=repository.following(null);assertTrue(first.more)
        assertFalse(repository.following(first.cursor).more)
    }
    @Test fun filteringAnUnfollowedPageCannotDiscardItsContinuation() = fixture({ page(true,"older-page",JSONArray().put(post("101",8))) }) { repository,_ ->
        val value=repository.following(null)
        assertTrue(value.items.isEmpty());assertTrue(value.more);assertEquals("older-page",value.cursor)
    }
    @Test fun booleanContinuationStillRejectsMissingItems() = fixture({ page(true,"older-page",null) }) { repository,_ ->
        try { repository.following(null);fail("A malformed continued page must not look like the end") }
        catch(e: BiliFailure) { assertEquals("INVALID_RESPONSE",e.code) }
    }
    @Test fun booleanContinuationStillRejectsARepeatedCursor() = fixture({ page(true,"same-page") }) { repository,_ ->
        try { repository.following("same-page");fail("A looping cursor must not look like the end") }
        catch(e: BiliFailure) { assertEquals("CURSOR_LOOP",e.code) }
    }
    @Test fun anUnknownFlagCannotMasqueradeAsTheEndOfTheFeed() = fixture({ page("unrecognized","older-page") }) { repository,_ ->
        try { repository.following(null);fail("An unsupported flag must produce an explicit error") }
        catch(e: BiliFailure) { assertEquals("INVALID_RESPONSE",e.code) }
    }
}

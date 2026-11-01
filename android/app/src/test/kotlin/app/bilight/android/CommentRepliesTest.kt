package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CommentRepliesTest {
    private fun repository(handler: (Request) -> JSONObject): BiliRepository {
        val client=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); assertEquals("GET",request.method)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(JSONObject().put("code",0).put("data",handler(request)).toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        return BiliRepository(BiliHttp(object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} },client))
    }
    private fun page(number: Int=1,count: Int=21,root: String="289123456789",replyRoot: String=root) = JSONObject()
        .put("page",JSONObject().put("num",number).put("size",20).put("count",count))
        .put("root",JSONObject().put("rpid_str",root).put("oid","1057955152016703512"))
        .put("replies",JSONArray().put(JSONObject().put("rpid_str","289123456790").put("root",replyRoot).put("oid","1057955152016703512").put("content",JSONObject().put("message","Child"))))
    @Test fun readsOnlyTheExplicitPageAndExactDynamicThread() = runBlocking {
        val repo=repository { request ->
            assertEquals("/x/v2/reply/reply",request.url.encodedPath)
            assertEquals("1057955152016703512",request.url.queryParameter("oid"))
            assertEquals("289123456789",request.url.queryParameter("root"))
            assertEquals("17",request.url.queryParameter("type"))
            page(number=request.url.queryParameter("pn")!!.toInt())
        }
        val first=repo.commentReplies("1057955152016703512",17,"289123456789")
        assertEquals(21,first.total); assertTrue(first.more); assertEquals("Child",first.items.first().text)
        assertFalse(repo.commentReplies("1057955152016703512",17,"289123456789",2).more)
    }
    @Test fun rejectsWrongRootsAndFakeEmptyPages() = runBlocking {
        for (data in listOf(page(root="99"),page(replyRoot="99"),page(count=40).put("replies",JSONArray()))) {
            try { repository { data }.commentReplies("1057955152016703512",17,"289123456789"); fail("Must reject incomplete or mismatched thread") }
            catch (_: BiliFailure) {}
        }
    }
}

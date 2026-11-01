package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DynamicLikesTest {
    private val id="1057955152016703512"
    private fun item(liked: Boolean,count: Long=12)=JSONObject().put("id_str",id).put("type","DYNAMIC_TYPE_WORD")
        .put("basic",JSONObject().put("comment_id_str",id).put("comment_type",17))
        .put("modules",JSONObject().put("module_author",JSONObject().put("mid",7).put("name","作者"))
            .put("module_dynamic",JSONObject().put("desc",JSONObject().put("text","动态正文")))
            .put("module_stat",JSONObject().put("like",JSONObject().put("count",count).put("status",liked))))
    private suspend fun repository(handler: (Request)->JSONObject): BiliRepository {
        val client=OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
            val request=chain.request()
            val data=when(request.url.encodedPath) {
                "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",3).put("uname","Test")
                "/x/frontend/finger/spi" -> JSONObject().put("b_3","test-official-device")
                else -> handler(request)
            }
            val raw=if(data.has("code")) data else JSONObject().put("code",0).put("data",data)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(raw.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        val http=BiliHttp(object: SecureStore { override fun load(): ByteArray?=null;override fun save(bytes: ByteArray) {};override fun clear() {} },client)
        http.acceptLogin("SESSDATA=test-only; bili_jct=test-only")
        return BiliRepository(http)
    }
    @Test fun explicitLikeAndUnlikeReadFirstWriteJSONOnceAndConfirmActualCounts()=runBlocking {
        var liked=false;var reads=0;val writes=mutableListOf<Int>()
        val repo=repository { request ->
            if(request.method=="POST") {
                assertTrue(reads>0);assertEquals("/x/dynamic/feed/dyn/thumb",request.url.encodedPath)
                assertEquals("test-only",request.url.queryParameter("csrf"));assertEquals("application/json; charset=utf-8",request.body!!.contentType().toString())
                val buffer=Buffer();request.body!!.writeTo(buffer);val body=JSONObject(buffer.readUtf8())
                assertEquals(id,body.getString("dyn_id_str"));val up=body.getInt("up");writes.add(up);liked=up==1
                JSONObject().put("code",0).put("data",JSONObject.NULL)
            } else { reads++;JSONObject().put("item",item(liked,if(liked) 19 else 18)) }
        }
        assertEquals(19L,repo.setDynamicLike(id,true).likes)
        repo.setDynamicLike(id,true);assertEquals(listOf(1),writes)
        assertFalse(repo.setDynamicLike(id,false).liked);assertEquals(listOf(1,2),writes)
    }
    @Test fun failedWriteIsNeverRetriedAndMalformedReadCannotAuthorizeAWrite()=runBlocking {
        var writes=0;var reads=0
        val repo=repository { request ->
            if(request.method=="POST") { writes++;JSONObject().put("code",-403).put("message","Denied") }
            else { reads++;JSONObject().put("item",item(false)) }
        }
        try { repo.setDynamicLike(id,true);fail("Unconfirmed write must fail") } catch (_: BiliFailure) {}
        assertEquals(1,writes);assertEquals(4,reads)
        val malformed=repository { request -> assertEquals("GET",request.method);JSONObject().put("item",item(false).apply { obj("modules").obj("module_stat").obj("like").put("status",0.5) }) }
        try { malformed.setDynamicLike(id,true);fail("Ambiguous state cannot authorize a write") } catch (_: BiliFailure) {}
    }
}

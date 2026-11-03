package app.bilight.android

import androidx.activity.compose.setContent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import app.bilight.android.core.*
import app.bilight.android.ui.MainApp
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Exercise cached lazy-list buttons and late responses without touching a real account. */
class DynamicLikeLifecycleTest {
    @get:Rule val rule=createAndroidComposeRule<MainActivity>()
    private fun await(condition: () -> Boolean) = rule.waitUntil(5000) {
        var value=false; rule.runOnUiThread { value=condition() }; value
    }
    @Test fun cachedCardsAndOffscreenConfirmationsSurviveRepeatedLikeAndUnlike() {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish") && SessionVault(app).load()==null)
        val liked=ConcurrentHashMap<String,Boolean>(); val writes=AtomicInteger()
        val rejected=AtomicBoolean(false); val otherLikes=AtomicInteger()
        var gate: CountDownLatch?=null
        val store=ViewModelStore()
        fun post(id: String)=JSONObject().put("id_str",id).put("type","DYNAMIC_TYPE_WORD")
            .put("basic",JSONObject().put("comment_id_str",id).put("comment_type",17))
            .put("modules",JSONObject()
                .put("module_author",JSONObject().put("mid",7).put("name","隔离点赞作者").put("pub_ts",1700000000))
                .put("module_dynamic",JSONObject().put("desc",JSONObject().put("text","第${id}条动态点赞回归\n滚动后等待点赞确认。\n只使用隔离数据。")))
                .put("module_stat",JSONObject().put("like",JSONObject().put("count",(if(liked[id]==true) 13 else 12)+otherLikes.get()).put("status",liked[id]==true))))
        val client=OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
            val request=chain.request(); val path=request.url.encodedPath
            val data=when(path) {
                "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",900000004).put("uname","隔离点赞账号")
                "/x/frontend/finger/spi" -> JSONObject().put("b_3","FIXTURE-ISSUED-DEVICE-1234")
                "/x/relation/relations" -> JSONObject().put("7",JSONObject().put("attribute",2))
                "/x/polymer/web-dynamic/v1/feed/all" -> JSONObject().put("has_more",0).put("offset","")
                    .put("items",JSONArray((1..40).map { post((1000+it).toString()) }))
                "/x/polymer/web-dynamic/v1/detail" -> JSONObject().put("item",post(request.url.queryParameter("id")!!))
                "/x/dynamic/feed/dyn/thumb" -> {
                    check(request.method=="POST"); writes.incrementAndGet()
                    val buffer=Buffer(); request.body!!.writeTo(buffer); val body=JSONObject(buffer.readUtf8())
                    check(gate?.await(15,TimeUnit.SECONDS)!=false)
                    if(rejected.get()) JSONObject().put("code",-403).put("message","隔离点赞失败")
                    else { liked[body.getString("dyn_id_str")]=body.getInt("up")==1; JSONObject() }
                }
                else -> error("Unexpected isolated endpoint: $path")
            }
            val raw=if(data.has("code")) data else JSONObject().put("code",0).put("data",data)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(raw.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        try {
            val memory=object: SecureStore { var value: ByteArray?=null; override fun load()=value; override fun save(bytes: ByteArray) { value=bytes }; override fun clear() { value=null } }
            val http=BiliHttp(memory,client); runBlocking { http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only") }
            lateinit var model: AppModel
            rule.runOnUiThread { model=ViewModelProvider(store,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) as T
            })[AppModel::class.java] }
            await { !model.restoring }
            rule.runOnUiThread { model.tab=1; rule.activity.setContent { MainApp(model) } }
            await { model.feedLoaded && !model.feedBusy }
            repeat(3) { round ->
                listOf(12,25,3,34).forEachIndexed { index,position ->
                    val id=(1001+position).toString(); val target=round%2==0
                    val before=writes.get(); gate=CountDownLatch(1)
                    rule.onNode(hasScrollAction()).performScrollToIndex(position)
                    rule.onNodeWithTag("dynamic-like-$id").performClick()
                    await { writes.get()==before+1 }
                    rule.onNodeWithTag("dynamic-like-$id").assertIsNotEnabled().assertContentDescriptionEquals(
                        (if(target) "取消动态点赞" else "点赞动态")+"，${if(target) 13 else 12}赞，正在处理").assertTextEquals(if(target) "13" else "12")
                    // Detach the clicked card before its real model request publishes the result.
                    rule.onNode(hasScrollAction()).performScrollToIndex(if(position<20) 30 else 0)
                    gate!!.countDown()
                    await { model.dynamicLikeStates[id]?.liked==target && !model.dynamicLikePending.containsKey(id) }
                    assertNull(model.error); assertEquals(before+1,writes.get())
                    rule.onNode(hasScrollAction()).performScrollToIndex(position)
                    rule.onNodeWithTag("dynamic-like-$id").assertIsEnabled().assertContentDescriptionEquals(
                        (if(target) "取消动态点赞" else "点赞动态")+"，${if(target) 13 else 12}赞")
                    assertEquals(round*4+index+1,writes.get())
                }
            }
            // Both rejected likes and rejected unlikes must restore the complete prior display.
            rejected.set(true)
            listOf(12,0).forEach { position ->
                val id=(1001+position).toString(); val before=writes.get()
                val confirmed=model.dynamicLikeState(model.following[position]); val target=!confirmed.liked
                val preview=confirmed.likes+if(target) 1 else -1
                gate=CountDownLatch(1)
                rule.onNode(hasScrollAction()).performScrollToIndex(position)
                rule.onNodeWithTag("dynamic-like-$id").performClick()
                await { writes.get()==before+1 }
                rule.onNodeWithTag("dynamic-like-$id").assertContentDescriptionEquals(
                    (if(target) "取消动态点赞" else "点赞动态")+"，${preview}赞，正在处理").assertTextEquals("$preview")
                gate.countDown()
                await { !model.dynamicLikePending.containsKey(id) && model.error!=null }
                assertEquals(confirmed,model.dynamicLikeState(model.following[position])); assertEquals(before+1,writes.get())
                rule.runOnIdle { model.error=null }
                rule.onNodeWithTag("dynamic-like-$id").assertIsEnabled().assertContentDescriptionEquals(
                    (if(confirmed.liked) "取消动态点赞" else "点赞动态")+"，${confirmed.likes}赞").assertTextEquals("${confirmed.likes}")
            }
            // A confirmed total may include other viewers' likes; adopt it without adding twice.
            rejected.set(false); gate=CountDownLatch(1)
            rule.onNodeWithTag("dynamic-like-1001").performClick()
            await { writes.get()==15 }
            rule.onNodeWithTag("dynamic-like-1001").assertTextEquals("13")
            otherLikes.set(5); gate.countDown()
            await { !model.dynamicLikePending.containsKey("1001") && model.dynamicLikeStates["1001"]?.likes==18L }
            rule.onNodeWithTag("dynamic-like-1001").assertIsEnabled().assertContentDescriptionEquals("取消动态点赞，18赞").assertTextEquals("18")
            assertNull(model.error); assertEquals(15,writes.get())
        } finally { gate?.countDown(); rule.runOnUiThread { store.clear() }; client.dispatcher.cancelAll() }
    }
}

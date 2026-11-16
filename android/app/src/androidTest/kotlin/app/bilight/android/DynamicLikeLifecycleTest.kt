package app.bilight.android

import android.os.SystemClock
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
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

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
        val dropLikeResponse=AtomicBoolean(false); val hiddenDetailReads=AtomicInteger()
        val staleFeed=AtomicReference<Boolean?>(null); val detailRechecks=AtomicInteger()
        val gate=AtomicReference<CountDownLatch?>(); val lastWriteAt=AtomicLong()
        fun holdNextWrite()=CountDownLatch(1).also(gate::set)
        var detailGate: CountDownLatch?=null
        val likedComments=ConcurrentHashMap<String,Boolean>(); val commentWrites=AtomicInteger()
        val commentGate=AtomicReference<CountDownLatch?>(); val moreCommentLikes=AtomicInteger()
        val store=ViewModelStore()
        fun comment(id: String) = JSONObject().put("rpid_str",id).put("oid_str","1001").put("type",17)
            .put("root_str",if (id=="201") "0" else "201").put("rcount",if (id=="201") 1 else 0)
            .put("like",5+moreCommentLikes.get()+if (likedComments[id]==true) 1 else 0)
            .put("action",if (likedComments[id]==true) 1 else 0)
            .put("member",JSONObject().put("mid",9).put("uname","隔离评论作者"))
            .put("content",JSONObject().put("message",if (id=="201") "隔离主评论" else "隔离楼中楼"))
        fun post(id: String, fromFeed: Boolean = false, hideLike: Boolean = false): JSONObject {
            val staleStatus=if (fromFeed && id=="1001") staleFeed.get() else null
            val isLiked=!hideLike && liked[id]==true
            return JSONObject().put("id_str",id).put("type","DYNAMIC_TYPE_WORD")
            .put("basic",JSONObject().put("comment_id_str",id).put("comment_type",17))
            .put("modules",JSONObject()
                .put("module_author",JSONObject().put("mid",7).put("name","隔离点赞作者").put("pub_ts",1700000000))
                .put("module_dynamic",JSONObject().put("desc",JSONObject().put("text","第${id}条动态点赞回归\n滚动后等待点赞确认。\n只使用隔离数据。")))
                .put("module_stat",JSONObject().put("like",JSONObject()
                    .put("count",if (staleStatus!=null) 12345 else (if (id=="1001") 12345 else 12)+(if (isLiked) 1 else 0)+otherLikes.get())
                    .put("status",staleStatus ?: isLiked))))
        }
        val client=OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
            val request=chain.request(); val path=request.url.encodedPath
            val data=when(path) {
                "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",900000004).put("uname","隔离点赞账号")
                    .put("wbi_img",JSONObject().put("img_url","https://i0.hdslb.com/${"a".repeat(32)}.png")
                        .put("sub_url","https://i0.hdslb.com/${"b".repeat(32)}.png"))
                "/x/frontend/finger/spi" -> JSONObject().put("b_3","FIXTURE-ISSUED-DEVICE-1234")
                "/x/relation/relations" -> JSONObject().put("7",JSONObject().put("attribute",2))
                "/x/polymer/web-dynamic/v1/feed/all" -> JSONObject().put("has_more",0).put("offset","")
                    .put("items",JSONArray((1..40).map { post((1000+it).toString(),fromFeed=true) }))
                "/x/polymer/web-dynamic/v1/detail" -> {
                    val id=request.url.queryParameter("id")!!
                    if (id=="1001" && staleFeed.get()!=null) {
                        detailRechecks.incrementAndGet()
                        check(detailGate?.await(15,TimeUnit.SECONDS)!=false)
                    }
                    val hideLike=id=="1001" && hiddenDetailReads.getAndUpdate { (it-1).coerceAtLeast(0) }>0
                    JSONObject().put("item",post(id,hideLike=hideLike))
                }
                "/x/dynamic/feed/dyn/thumb" -> {
                    check(request.method=="POST")
                    val writeGate=gate.get(); lastWriteAt.set(SystemClock.elapsedRealtime()); writes.incrementAndGet()
                    val buffer=Buffer(); request.body!!.writeTo(buffer); val body=JSONObject(buffer.readUtf8())
                    check(writeGate?.await(15,TimeUnit.SECONDS)!=false)
                    if (dropLikeResponse.getAndSet(false)) {
                        check(body.getString("dyn_id_str")=="1001" && body.getInt("up")==1)
                        liked["1001"]=true; hiddenDetailReads.set(3)
                        throw IOException("隔离写入响应丢失")
                    }
                    if(rejected.get()) JSONObject().put("code",-403).put("message","隔离点赞失败")
                    else { liked[body.getString("dyn_id_str")]=body.getInt("up")==1; JSONObject() }
                }
                "/x/v2/reply/wbi/main" -> JSONObject().put("cursor",JSONObject().put("is_end",true).put("all_count",1))
                    .put("replies",JSONArray().put(comment("201")))
                "/x/v2/reply/reply" -> JSONObject().put("page",JSONObject().put("num",1).put("size",20).put("count",1))
                    .put("root",comment("201")).put("replies",JSONArray().put(comment("202")))
                "/x/v2/reply/detail" -> {
                    check(request.url.queryParameter("oid")=="1001" && request.url.queryParameter("type")=="17")
                    JSONObject().put("root",comment(request.url.queryParameter("root")!!))
                }
                "/x/v2/reply/action" -> {
                    check(request.method=="POST")
                    val form=request.body as FormBody
                    val fields=(0 until form.size).associate { form.name(it) to form.value(it) }
                    check(fields["oid"]=="1001" && fields["type"]=="17" && fields["rpid"]=="202")
                    val writeGate=commentGate.get(); commentWrites.incrementAndGet()
                    check(writeGate?.await(15,TimeUnit.SECONDS)!=false)
                    likedComments["202"]=fields["action"]=="1"
                    JSONObject()
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
                    val before=writes.get(); val writeGate=holdNextWrite()
                    rule.onNode(hasScrollAction()).performScrollToIndex(position)
                    rule.onNodeWithTag("dynamic-like-$id").performClick()
                    await { writes.get()==before+1 }
                    rule.onNodeWithTag("dynamic-like-$id").assertIsEnabled().assertContentDescriptionEquals(
                        (if(target) "取消动态点赞" else "点赞动态")+"，${if(target) 13 else 12}赞，正在处理").assertTextEquals(if(target) "13" else "12")
                    // Detach the clicked card before its real model request publishes the result.
                    rule.onNode(hasScrollAction()).performScrollToIndex(if(position<20) 30 else 0)
                    writeGate.countDown()
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
                val writeGate=holdNextWrite()
                rule.onNode(hasScrollAction()).performScrollToIndex(position)
                rule.onNodeWithTag("dynamic-like-$id").performClick()
                await { writes.get()==before+1 }
                rule.onNodeWithTag("dynamic-like-$id").assertContentDescriptionEquals(
                    (if(target) "取消动态点赞" else "点赞动态")+"，${preview}赞，正在处理").assertTextEquals("$preview")
                writeGate.countDown()
                await { !model.dynamicLikePending.containsKey(id) && model.error!=null }
                assertEquals(confirmed,model.dynamicLikeState(model.following[position])); assertEquals(before+1,writes.get())
                rule.runOnIdle { model.error=null }
                rule.onNodeWithTag("dynamic-like-$id").assertIsEnabled().assertContentDescriptionEquals(
                    (if(confirmed.liked) "取消动态点赞" else "点赞动态")+"，${confirmed.likes}赞").assertTextEquals("${confirmed.likes}")
            }
            // Keep single likes visible above 10,000 and adopt the full total after confirmation.
            rejected.set(false); val writeGate=holdNextWrite()
            rule.onNodeWithTag("dynamic-like-1001").assertTextEquals("12345")
            rule.onNodeWithTag("dynamic-like-1001").performClick()
            await { writes.get()==15 }
            rule.onNodeWithTag("dynamic-like-1001").assertTextEquals("12346")
            otherLikes.set(5); writeGate.countDown()
            await { !model.dynamicLikePending.containsKey("1001") && model.dynamicLikeStates["1001"]?.likes==12351L }
            rule.onNodeWithTag("dynamic-like-1001").assertIsEnabled().assertContentDescriptionEquals("取消动态点赞，12351赞").assertTextEquals("12351")
            assertNull(model.error); assertEquals(15,writes.get())

            // The refreshed feed may lag on the total even with a matching like status.
            detailGate=CountDownLatch(1); staleFeed.set(true)
            rule.runOnUiThread { model.loadFeed(true) }
            await { !model.feedBusy }
            rule.onNodeWithTag("dynamic-like-1001").assertContentDescriptionEquals("取消动态点赞，12351赞").assertTextEquals("12351")
            await { detailRechecks.get()==1 }; otherLikes.set(6); detailGate.countDown()
            await { model.dynamicLikeStates["1001"]==DynamicLikeState(true,12352L) }
            rule.onNodeWithTag("dynamic-like-1001").assertTextEquals("12352")
            assertEquals(15,writes.get())

            // A refreshed feed may also lag on the account's like status.
            detailGate=CountDownLatch(1); staleFeed.set(false)
            rule.runOnUiThread { model.loadFeed(true) }
            await { !model.feedBusy }
            rule.onNodeWithTag("dynamic-like-1001").assertContentDescriptionEquals("取消动态点赞，12352赞")
            await { detailRechecks.get()==2 }; otherLikes.set(7); detailGate.countDown()
            await { model.dynamicLikeStates["1001"]==DynamicLikeState(true,12353L) }

            // An actual unlike from another client still appears after detail revalidation.
            liked["1001"]=false
            rule.runOnUiThread { model.loadFeed(true) }
            await { !model.feedBusy && model.dynamicLikeStates["1001"]==DynamicLikeState(false,12352L) }
            rule.onNodeWithTag("dynamic-like-1001").assertContentDescriptionEquals("点赞动态，12352赞").assertTextEquals("12352")
            assertEquals(3,detailRechecks.get()); assertEquals(15,writes.get()); assertNull(model.error)

            staleFeed.set(null)
            val button=rule.onNodeWithTag("dynamic-like-1001")
            fun tapShowing(value: String) { button.assertIsEnabled().performClick().assertTextEquals(value) }
            tapShowing("12353"); tapShowing("12352")
            await { !model.dynamicLikePending.containsKey("1001") }
            assertEquals(15,writes.get())

            val earlierWrite=holdNextWrite()
            tapShowing("12353")
            Thread.sleep(250)
            tapShowing("12352")
            val lastTap=SystemClock.elapsedRealtime()
            tapShowing("12353")
            assertEquals(15,writes.get())
            await { writes.get()==16 }
            assertTrue(lastWriteAt.get()-lastTap>=800)

            // A late successful like with a higher real total must stay invisible while unlike is queued.
            val latestTap=SystemClock.elapsedRealtime()
            tapShowing("12352")
            val latestWrite=holdNextWrite(); otherLikes.set(9); earlierWrite.countDown()
            await { model.dynamicLikeStates["1001"]==DynamicLikeState(true,12355L) }
            button.assertContentDescriptionEquals("点赞动态，12352赞，正在处理").assertTextEquals("12352")
            await { writes.get()==17 }
            assertTrue(lastWriteAt.get()-latestTap>=800)
            otherLikes.set(11); latestWrite.countDown()
            await { !model.dynamicLikePending.containsKey("1001") }
            button.assertContentDescriptionEquals("点赞动态，12356赞").assertTextEquals("12356")

            // A superseded rejection must not roll back the newest unlike or trigger another POST.
            rejected.set(true); val supersededWrite=holdNextWrite()
            tapShowing("12357")
            await { writes.get()==18 }
            tapShowing("12356"); otherLikes.set(12); supersededWrite.countDown()
            await { !model.dynamicLikePending.containsKey("1001") }
            button.assertContentDescriptionEquals("点赞动态，12356赞").assertTextEquals("12356")
            assertNull(model.error); assertEquals(18,writes.get())

            // A lost response can leave the server liked even after the UI rolls back.
            rejected.set(false); dropLikeResponse.set(true); val lostWrite=holdNextWrite()
            tapShowing("12357"); await { writes.get()==19 }; lostWrite.countDown()
            await { !model.dynamicLikePending.containsKey("1001") && model.error!=null }
            rule.runOnIdle { model.error=null }
            button.assertContentDescriptionEquals("点赞动态，12356赞").assertTextEquals("12356")
            val recoveryWrite=holdNextWrite()
            tapShowing("12357"); tapShowing("12356")
            await { writes.get()==20 }; recoveryWrite.countDown()
            await { !model.dynamicLikePending.containsKey("1001") }
            button.assertContentDescriptionEquals("点赞动态，12357赞").assertTextEquals("12357")
            assertEquals(false,liked["1001"]); assertNull(model.error); assertEquals(20,writes.get())

            // The actual main comment and reply controls share this behavior on a dynamic thread.
            rule.onNodeWithTag("dynamic-open-1001").performClick()
            rule.waitUntil(5000) { rule.onAllNodesWithTag("video-comment-like-201").fetchSemanticsNodes().isNotEmpty() }
            val mainLike=rule.onNodeWithTag("video-comment-like-201")
            mainLike.performClick().assertTextEquals("6")
            mainLike.assertIsEnabled().performClick().assertTextEquals("5")
            await { appCommentSettled(model,"201") }
            assertEquals(0,commentWrites.get())
            rule.onNodeWithTag("comment-expand-201").performClick()
            rule.waitUntil(5000) { rule.onAllNodesWithTag("video-comment-like-202").fetchSemanticsNodes().isNotEmpty() }
            val replyLike=rule.onNodeWithTag("video-comment-like-202")
            val firstCommentWrite=CountDownLatch(1).also(commentGate::set)
            replyLike.performClick().assertTextEquals("6")
            await { commentWrites.get()==1 }
            replyLike.assertIsEnabled().performClick().assertTextEquals("5")
            val secondCommentWrite=CountDownLatch(1).also(commentGate::set)
            moreCommentLikes.set(4); firstCommentWrite.countDown()
            await { model.commentLikes.confirmed[Triple("1001",17,"202")]==CommentLikeState(true,10L) }
            replyLike.assertTextEquals("5")
            await { commentWrites.get()==2 }; secondCommentWrite.countDown()
            await { appCommentSettled(model,"202") }
            replyLike.assertTextEquals("9")
            assertEquals(2,commentWrites.get())
        } finally { gate.get()?.countDown(); commentGate.get()?.countDown(); detailGate?.countDown(); rule.runOnUiThread { store.clear() }; client.dispatcher.cancelAll() }
    }

    private fun appCommentSettled(model: AppModel,id: String) = Triple("1001",17,id) !in model.commentLikes.pending
}

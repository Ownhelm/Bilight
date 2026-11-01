package app.bilight.android

import androidx.activity.compose.setContent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.graphics.asAndroidBitmap
import java.io.File
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import app.bilight.android.core.*
import app.bilight.android.core.Route
import app.bilight.android.ui.MainApp
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Delay both actual screen reads independently; no real account or network is used. */
class DynamicLoadingTest {
    @get:Rule val rule=createAndroidComposeRule<MainActivity>()
    private val id="1057955152016703512"
    private val progress=SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)
    private fun fixture(commentsFirst: Boolean) {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish") && SessionVault(app).load()==null)
        val detailGate=CountDownLatch(1);val commentsGate=CountDownLatch(1)
        val detailReads=AtomicInteger();val commentReads=AtomicInteger()
        val raw=JSONObject().put("id_str",id).put("type","DYNAMIC_TYPE_WORD")
            .put("basic",JSONObject().put("comment_id_str",id).put("comment_type",17))
            .put("modules",JSONObject().put("module_author",JSONObject().put("mid",7).put("name","隔离作者"))
                .put("module_dynamic",JSONObject().put("desc",JSONObject().put("text","动态加载回归")))
                .put("module_stat",JSONObject().put("like",JSONObject().put("count",12).put("status",false))))
        val client=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request();check(request.method=="GET")
            val data=when(request.url.encodedPath) {
                "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",900000003).put("uname","隔离账号")
                    .put("wbi_img",JSONObject().put("img_url","https://i0.hdslb.com/"+"a".repeat(32)+".png").put("sub_url","https://i0.hdslb.com/"+"b".repeat(32)+".png"))
                "/x/frontend/finger/spi" -> JSONObject().put("b_3","FIXTURE-ISSUED-DEVICE-1234")
                "/x/polymer/web-dynamic/v1/detail" -> { detailReads.incrementAndGet();check(detailGate.await(20,TimeUnit.SECONDS));JSONObject().put("item",raw) }
                "/x/v2/reply/wbi/main" -> { commentReads.incrementAndGet();check(commentsGate.await(20,TimeUnit.SECONDS));JSONObject().put("cursor",JSONObject().put("is_end",true).put("all_count",0)).put("replies",JSONArray()) }
                else -> error("Unexpected fixture request: ${request.url.encodedPath}")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(JSONObject().put("code",0).put("data",data).toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        val store=ViewModelStore()
        try {
            val memory=object: SecureStore { var value: ByteArray?=null;override fun load()=value;override fun save(bytes: ByteArray) { value=bytes };override fun clear() { value=null } }
            val http=BiliHttp(memory,client);runBlocking { http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only") }
            lateinit var model: AppModel
            rule.runOnUiThread { model=ViewModelProvider(store,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) as T
            })[AppModel::class.java] }
            rule.waitUntil(5000) { !model.restoring }
            rule.runOnUiThread { model.open(Route.Dynamic(Post.parse(raw)!!));rule.activity.setContent { MainApp(model) } }
            rule.waitUntil(5000) { detailReads.get()==1 && commentReads.get()==1 }
            rule.onAllNodes(progress).assertCountEquals(1)
            val image=rule.onRoot().captureToImage().asAndroidBitmap()
            File(app.cacheDir,"dynamic-loading-${if(commentsFirst) "comments-first" else "detail-first"}.png").outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }
            if(commentsFirst) commentsGate.countDown() else detailGate.countDown()
            rule.waitUntil(5000) { rule.onAllNodesWithText(if(commentsFirst) "正在读取动态" else "正在加载评论").fetchSemanticsNodes().size==1 }
            rule.onAllNodes(progress).assertCountEquals(1)
            detailGate.countDown();commentsGate.countDown()
            rule.waitUntil(5000) { rule.onAllNodes(progress).fetchSemanticsNodes().isEmpty() }
            assertEquals(1,detailReads.get());assertEquals(1,commentReads.get())
        } finally { detailGate.countDown();commentsGate.countDown();rule.runOnUiThread { store.clear() };client.dispatcher.cancelAll() }
    }
    @Test fun detailAndCommentsHaveOneIndicatorUntilBothComplete()=fixture(false)
    @Test fun fasterCommentsDoNotHideTheRemainingDetailRead()=fixture(true)
}

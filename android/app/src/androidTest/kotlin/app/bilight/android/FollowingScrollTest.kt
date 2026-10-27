package app.bilight.android

import android.view.ViewGroup
import androidx.compose.ui.test.*
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
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Native user swipes, including a footer that cannot move because a page added no new posts. */
class FollowingScrollTest {
    @get:Rule val rule=createAndroidComposeRule<MainActivity>()
    private fun await(message: String,condition: () -> Boolean) {
        try { rule.waitUntil(5000) { var value=false;rule.runOnUiThread { value=condition() };value } }
        catch(e: Throwable) { throw AssertionError(message,e) }
    }
    private fun swipe() { rule.onNode(hasScrollAction()).performTouchInput { swipeUp(durationMillis=250) } }
    private fun fixture(test: (Fixture) -> Unit) {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish") && SessionVault(app).load()==null)
        rule.runOnUiThread { rule.activity.findViewById<ViewGroup>(android.R.id.content).removeAllViews() }
        val f=Fixture(app)
        try {
            await("The isolated account did not restore") { !f.model.restoring }
            rule.runOnIdle { f.model.tab=1 }
            rule.setContent { MainApp(f.model) }
            await("The first real model page did not load") { f.model.feedLoaded && !f.model.feedBusy }
            test(f)
        } finally { f.gate?.countDown();rule.runOnUiThread { f.store.clear() };f.client.dispatcher.cancelAll() }
    }
    @Test fun aUserSwipeAtAnUnmovingFooterLoadsTheNextPageWithoutReloadingOnReturn() = fixture { f ->
        rule.runOnIdle { f.model.open(Route.Downloads) };rule.waitForIdle()
        rule.runOnIdle { f.model.back() };rule.waitForIdle()
        assertEquals("Returning to the cached footer prefetched another page",listOf("first"),f.offsets.toList())
        swipe()
        await("Swiping a visible footer that cannot move failed to load the next page") { f.model.following.size==2 }
        assertEquals(listOf("first","next"),f.offsets.toList())
        assertFalse(f.model.feedMore)
    }
    @Test fun scrollingDuringALoadSurvivesADuplicatePageAndContinuesItsNewCursor() = fixture { f ->
        f.duplicate=true;f.gate=CountDownLatch(1)
        rule.runOnIdle { f.model.loadFeed() }
        await("The delayed second page did not begin") { f.offsets.size==2 }
        swipe();f.gate!!.countDown()
        await("A duplicate page stranded the continued user scroll at the same footer") { f.model.following.size==2 }
        assertEquals(listOf("first","next","after-duplicate"),f.offsets.toList())
        assertEquals(listOf("101","102"),f.model.following.map { it.id })
    }
    @Test fun aPagingErrorDoesNotAutoRetryWhenTheBusyStateChanges() = fixture { f ->
        f.fail=true;f.gate=CountDownLatch(1)
        rule.runOnIdle { f.model.loadFeed() }
        await("The delayed second page did not begin") { f.offsets.size==2 }
        swipe();f.gate!!.countDown()
        await("The genuine page error was not shown") { f.model.feedError!=null && !f.model.feedBusy }
        swipe();rule.waitForIdle()
        assertEquals("A failed page was retried without explicit retry",2,f.offsets.size)
        assertEquals(listOf("101"),f.model.following.map { it.id })
        f.fail=false
        rule.onNodeWithText("重试").performClick()
        await("Explicit retry did not use the unchanged failed cursor") { f.model.following.size==2 }
        assertEquals(listOf("first","next","next"),f.offsets.toList())
    }
    private inner class Fixture(app: BilightApplication) {
        val offsets=CopyOnWriteArrayList<String>()
        @Volatile var duplicate=false
        @Volatile var fail=false
        @Volatile var gate: CountDownLatch?=null
        val store=ViewModelStore()
        private fun post(id: String)=JSONObject().put("id_str",id).put("type","DYNAMIC_TYPE_WORD").put("modules",JSONObject()
            .put("module_author",JSONObject().put("mid",7).put("name","分页测试作者").put("pub_ts",1700000000))
            .put("module_dynamic",JSONObject().put("desc",JSONObject().put("text","第${id}条关注动态"))))
        val client=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request()
            val data=when(request.url.encodedPath) {
                "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",900000002).put("uname","隔离分页账号")
                "/x/frontend/finger/spi" -> JSONObject().put("b_3","FIXTURE-ISSUED-DEVICE-1234").put("b_4","FIXTURE-ISSUED-DEVICE-5678")
                "/x/relation/relations" -> JSONObject().put("7",JSONObject().put("attribute",2))
                "/x/polymer/web-dynamic/v1/feed/all" -> {
                    val offset=request.url.queryParameter("offset") ?: "first";offsets+=offset
                    if(offset=="next") check(gate?.await(5,TimeUnit.SECONDS)!=false)
                    if(fail && offset=="next") null else {
                        val continued=offset=="first" || offset=="next" && duplicate
                        JSONObject().put("has_more",if(continued) 1 else 0).put("offset",if(offset=="first") "next" else if(continued) "after-duplicate" else "")
                            .put("items",JSONArray().put(post(if(offset=="first" || continued) "101" else "102")))
                    }
                }
                else -> error("Unexpected isolated endpoint")
            }
            val body=if(data==null) JSONObject().put("code",-352).put("message","隔离分页错误") else JSONObject().put("code",0).put("data",data)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        val model: AppModel
        init {
            val memory=object: SecureStore { var value: ByteArray?=null;override fun load()=value;override fun save(bytes: ByteArray) { value=bytes };override fun clear() { value=null } }
            val http=BiliHttp(memory,client)
            runBlocking { http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only") }
            lateinit var value: AppModel
            rule.runOnUiThread { value=ViewModelProvider(store,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) as T
            })[AppModel::class.java] }
            model=value
        }
    }
}

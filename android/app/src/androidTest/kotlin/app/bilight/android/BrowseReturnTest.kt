package app.bilight.android

import androidx.activity.compose.setContent
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import app.bilight.android.core.*
import app.bilight.android.core.Route
import app.bilight.android.ui.MainApp
import app.bilight.android.ui.SearchCapsuleColor
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

/** Real navigation into the playback screen; all upstream reads/writes stay in the fixture. */
class BrowseReturnTest {
    @get:Rule val rule=createAndroidComposeRule<MainActivity>()
    private val list=SemanticsMatcher.keyIsDefined(SemanticsActions.ScrollToIndex)
    private fun position()=rule.onNode(list).fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()
    private fun await(test: () -> Boolean)=rule.waitUntil(5000,test)
    private fun fixture(searchParity: Boolean = false, test: (AppModel,CopyOnWriteArrayList<String>) -> Unit) {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish") && SessionVault(app).load()==null)
        val preferences = app.getSharedPreferences("video-search-preferences", android.content.Context.MODE_PRIVATE)
        if (searchParity) preferences.edit().clear().commit()
        val requests=CopyOnWriteArrayList<String>(); val store=ViewModelStore()
        val client=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); val url=request.url; val path=url.encodedPath; requests+=path+"?"+url.encodedQuery
            fun videos(page: Int,count: Int=30)=JSONArray((1..count).map { i -> JSONObject().put("bvid","BV"+((page-1)*count+i).toString().padStart(10,'0')).put("aid",i).put("title","视频 $page-$i").put("duration",60).put("type",2).put("owner",JSONObject().put("mid",7).put("name","隔离UP")) })
            fun folder(mid: Int)=JSONObject().put("id",9).put("mid",mid).put("title","隔离收藏夹").put("media_count",40)
            val data=when(path) {
                "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",42).put("uname","隔离账号").put("wbi_img",JSONObject().put("img_url","https://i0.hdslb.com/"+"a".repeat(32)+".png").put("sub_url","https://i0.hdslb.com/"+"b".repeat(32)+".png"))
                "/x/frontend/finger/spi" -> JSONObject().put("b_3","FIXTURE-DEVICE-123456")
                "/x/relation" -> JSONObject().put("attribute",2)
                "/x/web-interface/wbi/search/type" -> {
                    val page = url.queryParameter("page")!!.toInt()
                    val items = when {
                        !searchParity -> videos(page)
                        url.queryParameter("search_type") == "bili_user" -> JSONArray().put(JSONObject().put("mid",7).put("uname","隔离UP"))
                        page == 1 -> videos(1,3).apply {
                            getJSONObject(0).put("title", "防抖 Ａ７ 实测")
                            getJSONObject(1).put("title", "防抖教程")
                            getJSONObject(2).put("title", "a7 防抖对比")
                        }
                        else -> videos(2,3).apply { getJSONObject(0).put("title", "A7 防抖第二页") }
                    }
                    JSONObject().put("numPages",2).put("result",items)
                }
                "/x/space/wbi/acc/info" -> JSONObject().put("mid",7).put("name","隔离UP")
                "/x/space/wbi/arc/search" -> JSONObject().put("list",JSONObject().put("vlist",videos(url.queryParameter("pn")!!.toInt()))).put("page",JSONObject().put("count",60))
                "/x/v3/fav/folder/created/list" -> JSONObject().put("count",1).put("list",JSONArray().put(folder(42)))
                "/x/v3/fav/folder/collected/list" -> JSONObject().put("count",1).put("list",JSONArray().put(folder(7)))
                "/x/v3/fav/resource/list" -> JSONObject().put("info",folder(7)).put("medias",videos(url.queryParameter("pn")!!.toInt(),20)).put("has_more",url.queryParameter("pn")=="1")
                else -> JSONObject()
            }
            val body=JSONObject().put("code",if(path=="/x/web-interface/wbi/view") -404 else 0).put("message","隔离播放器未提供媒体").put("data",data)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        try {
            val memory=object: SecureStore { var bytes: ByteArray?=null; override fun load()=bytes; override fun save(bytes: ByteArray) { this.bytes=bytes }; override fun clear() { bytes=null } }
            val http=BiliHttp(memory,client); runBlocking { http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only") }
            lateinit var model: AppModel
            rule.runOnUiThread { model=ViewModelProvider(store,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) as T
            })[AppModel::class.java] }
            await { !model.restoring }; rule.runOnUiThread { rule.activity.setContent { MainApp(model) } }
            test(model,requests)
        } finally {
            rule.runOnUiThread { store.clear() }; client.dispatcher.cancelAll()
            if (searchParity) preferences.edit().clear().commit()
        }
    }
    private fun roundTrip(model: AppModel,title: String="视频 2-7") {
        rule.onNode(list).performScrollToIndex(18); val before=position(); assertTrue(before>=17)
        rule.onNodeWithText(title).performClick()
        await { model.routes.lastOrNull() is Route.Watch }; rule.waitForIdle()
        rule.runOnIdle { model.back() }; rule.waitForIdle()
        assertEquals("Returning from playback reset the browsing position",before,position(),.02f)
        rule.onNodeWithText(title).assertIsDisplayed()
    }
    @Test fun searchRetainsLoadedPagesAndPositionAfterPlayback()=fixture { model,requests ->
        rule.runOnIdle { model.keyword="隔离搜索"; model.search() }; await { model.searchItems.size==30 }
        rule.runOnIdle { model.search(false) }; await { model.searchItems.size==60 }
        roundTrip(model)
        assertEquals(2,requests.count { it.startsWith("/x/web-interface/wbi/search/type?") })
        assertEquals(60,model.searchItems.size)
    }
    @Test fun searchCapsuleAndFiltersFollowTheIPhoneInteraction() = fixture(searchParity = true) { model, requests ->
        val field = rule.onNodeWithTag("search-field")
        val filter = rule.onNodeWithTag("video-search-filter")
        fun capsuleColors(): List<androidx.compose.ui.graphics.Color> {
            val pixels = field.captureToImage().toPixelMap()
            return listOf(pixels[pixels.width / 2, 1], pixels[pixels.width / 2, pixels.height / 8])
        }
        fun choose(label: String) {
            filter.performClick()
            rule.onNodeWithText(label).assertIsDisplayed().performClick()
        }
        filter.assertDoesNotExist()
        val idle = capsuleColors()
        field.performTouchInput { click(center) }.assertIsFocused()
        assertEquals(listOf(SearchCapsuleColor, SearchCapsuleColor), idle)
        assertEquals(idle, capsuleColors())
        field.performTextInput("A7 防抖")
        rule.onNodeWithTag("submit-search").performClick()
        await { model.searchItems.size == 3 }
        rule.onNodeWithText("防抖教程").assertIsDisplayed()
        field.performTouchInput { click(center) }.assertIsFocused()
        assertEquals(idle, capsuleColors())
        choose("仅标题匹配")
        rule.onNodeWithText("防抖教程").assertDoesNotExist()
        rule.onNodeWithText("防抖 Ａ７ 实测").assertIsDisplayed()
        assertEquals(1, requests.count { it.startsWith("/x/web-interface/wbi/search/type?") })
        rule.onNodeWithContentDescription("清空搜索").performClick()
        filter.assertIsDisplayed()
        choose("最新")
        await { !model.searchBusy && requests.any { it.contains("order=pubdate") } }
        assertTrue(requests.last { it.contains("order=pubdate") }.contains("keyword=A7%20"))
        rule.onNodeWithText("加载更多").performClick()
        await { model.searchVideos.any { it.title == "A7 防抖第二页" } }
        rule.onNodeWithText("UP 主").performClick()
        await { !model.searchBusy && model.searchItems.any { it is User } }
        filter.assertDoesNotExist()
        assertTrue(requests.any { it.contains("order=0") && it.contains("search_type=bili_user") })
        rule.onNodeWithText("视频").performClick()
        await { !model.searchBusy }
        choose("播放多")
        await { !model.searchBusy && requests.any { it.contains("order=click") } }
    }
    @Test fun creatorRetainsLoadedPagesAndPositionAfterPlayback()=fixture { model,requests ->
        rule.runOnIdle { model.open(Route.Creator(User(7,"隔离UP",null))) }
        await { rule.onAllNodesWithText("视频 1-1").fetchSemanticsNodes().isNotEmpty() }
        rule.onNode(list).performScrollToIndex(15); rule.onNodeWithText("加载更多").performClick()
        await { requests.count { it.startsWith("/x/space/wbi/arc/search?") }==2 }; rule.waitForIdle()
        roundTrip(model)
        assertEquals(2,requests.count { it.startsWith("/x/space/wbi/arc/search?") })
        assertEquals(1,requests.count { it.startsWith("/x/space/wbi/acc/info?") })
        rule.runOnIdle { model.back() }; rule.waitForIdle()
        rule.runOnIdle { model.open(Route.Creator(User(7,"隔离UP",null))) }
        await { requests.count { it.startsWith("/x/space/wbi/arc/search?") }==3 }; rule.waitForIdle()
        assertEquals("A new visit must not inherit a discarded navigation entry",0f,position(),.02f)
    }
    @Test fun favoritesRetainTheSelectedTabAndLoadedFolderPosition()=fixture { model,requests ->
        rule.runOnIdle { model.open(Route.Favorites) }; rule.onNodeWithText("我收藏的").performClick()
        await { rule.onAllNodesWithText("隔离收藏夹").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithText("隔离收藏夹").performClick()
        await { rule.onAllNodesWithText("视频 1-1").fetchSemanticsNodes().isNotEmpty() }
        rule.onNode(list).performScrollToIndex(10); rule.onNodeWithText("加载更多").performClick()
        await { requests.count { it.startsWith("/x/v3/fav/resource/list?") }==2 }; rule.waitForIdle()
        roundTrip(model,"视频 2-17")
        assertEquals(2,requests.count { it.startsWith("/x/v3/fav/resource/list?") })
        rule.runOnIdle { model.back() }; rule.waitForIdle()
        rule.onNodeWithText("我收藏的").assertIsSelected()
        assertEquals(1,requests.count { it.startsWith("/x/v3/fav/folder/collected/list?") })
    }
}

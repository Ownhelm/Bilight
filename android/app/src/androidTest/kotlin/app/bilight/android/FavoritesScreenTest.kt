package app.bilight.android

import androidx.activity.compose.setContent
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
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Production favorites screens, with all reads intercepted and no real account or writes. */
class FavoritesScreenTest {
    @get:Rule val rule=createAndroidComposeRule<MainActivity>()
    private fun awaitText(text: String) = rule.waitUntil(5000) { rule.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
    private fun fixture(test: (Fixture) -> Unit) {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish") && SessionVault(app).load()==null)
        val f=Fixture(app)
        try {
            rule.waitUntil(5000) { !f.model.restoring }
            rule.runOnUiThread { f.model.open(Route.Favorites); rule.activity.setContent { MainApp(f.model) } }
            awaitText("我创建的收藏夹")
            test(f)
        } finally { rule.runOnUiThread { f.store.clear() }; f.client.dispatcher.cancelAll() }
    }

    @Test fun switchingTabsKeepsValidEntriesAndRetryRepairsTheIncompleteRow() = fixture { f ->
        rule.onNodeWithText("我收藏的").performClick()
        awaitText("收藏的合集")
        rule.onNodeWithText("正常收藏夹").assertIsDisplayed()
        rule.onNodeWithText("B站返回的收藏条目信息不完整，请重试。").assertIsDisplayed()
        f.repaired=true
        rule.onNodeWithText("重新读取收藏目录").performScrollTo().performClick()
        awaitText("已恢复的收藏夹")
        rule.onNodeWithText("B站返回的收藏条目信息不完整，请重试。").assertDoesNotExist()
        rule.onNodeWithText("收藏的合集").assertExists(); rule.onNodeWithText("正常收藏夹").assertExists()
        assertEquals(2,f.paths.count { it=="/x/v3/fav/folder/collected/list" })
    }

    @Test fun openingACollectedSeasonUsesItsCatalogRatherThanTheFavoriteFolderApi() = fixture { f ->
        rule.onNodeWithText("我收藏的").performClick(); awaitText("收藏的合集")
        rule.onNodeWithText("收藏的合集").performClick(); awaitText("合集里的视频")
        rule.onNodeWithText("合集里的视频").assertIsDisplayed()
        assertTrue(f.paths.contains("/x/polymer/web-space/seasons_archives_list"))
        assertFalse(f.paths.contains("/x/v3/fav/resource/list"))
    }

    @Test fun directoryRequestFailuresStayVisibleAndCanBeRetried() = fixture { f ->
        f.failDirectory=true
        rule.onNodeWithText("我收藏的").performClick(); awaitText("收藏目录读取失败（-352）")
        rule.onNodeWithText("暂无收藏夹").assertDoesNotExist()
        f.failDirectory=false
        rule.onNodeWithText("重试").performClick(); awaitText("收藏的合集")
        rule.onNodeWithText("正常收藏夹").assertIsDisplayed()
    }

    private inner class Fixture(app: BilightApplication) {
        val store=ViewModelStore()
        val paths=CopyOnWriteArrayList<String>()
        @Volatile var repaired=false
        @Volatile var failDirectory=false
        val client=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); check(request.method=="GET")
            val path=request.url.encodedPath; paths+=path
            val data=when(path) {
                "/x/web-interface/nav" -> JSONObject("""{"isLogin":true,"mid":900000004,"uname":"隔离收藏账号"}""")
                "/x/v3/fav/folder/created/list" -> JSONObject("""{"count":1,"has_more":false,"list":[{"id":1,"mid":900000004,"title":"我创建的收藏夹","media_count":1}]}""")
                "/x/v3/fav/folder/collected/list" -> {
                    val damaged=if (repaired) """{"id":102,"mid":7,"title":"已恢复的收藏夹","media_count":1}""" else """{"id":0,"mid":0,"title":"失效条目","state":1}"""
                    JSONObject("""{"count":3,"has_more":false,"list":[{"id":100,"mid":7,"upper":{"mid":7,"name":"合集作者"},"title":"收藏的合集","media_count":1,"type":21},$damaged,{"id":101,"mid":8,"title":"正常收藏夹","media_count":2,"type":11}]}""")
                }
                "/x/polymer/web-space/seasons_archives_list" -> JSONObject("""{"meta":{"season_id":100,"mid":7,"name":"收藏的合集","total":1},"page":{"page_num":1,"page_size":30,"total":1},"archives":[{"bvid":"BV1NGZtBwELa","aid":1,"title":"合集里的视频","duration":60}]}""")
                else -> error("Unexpected isolated read: $path")
            }
            val body=if (failDirectory && path=="/x/v3/fav/folder/collected/list") JSONObject().put("code",-352).put("message","收藏目录读取失败") else JSONObject().put("code",0).put("data",data)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(body.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        val model: AppModel
        init {
            val memory=object: SecureStore { var value: ByteArray?=null; override fun load()=value; override fun save(bytes: ByteArray) { value=bytes }; override fun clear() { value=null } }
            val http=BiliHttp(memory,client); runBlocking { http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only") }
            lateinit var value: AppModel
            rule.runOnUiThread { value=ViewModelProvider(store,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) as T
            })[AppModel::class.java] }
            model=value
        }
    }
}

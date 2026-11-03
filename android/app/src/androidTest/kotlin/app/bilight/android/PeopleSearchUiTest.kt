package app.bilight.android

import androidx.activity.ComponentActivity
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
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

class PeopleSearchUiTest {
    @get:Rule val rule=createAndroidComposeRule<ComponentActivity>()
    @Test fun searchesLaterPagesThroughUserRowsAndClearsBackToTheList() {
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish"))
        val context=ApplicationProvider.getApplicationContext<BilightApplication>()
        val requests=CopyOnWriteArrayList<Request>(); val models=ViewModelStore(); val offline=AtomicBoolean(false)
        val client=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); requests+=request
            val data=when(request.url.encodedPath) {
                "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",42).put("uname","隔离账号")
                "/x/frontend/finger/spi" -> JSONObject().put("b_3","FIXTURE-DEVICE-123456")
                "/x/relation" -> JSONObject().put("attribute",2)
                "/x/space/wbi/acc/info" -> JSONObject().put("mid",21).put("name","小鹿Lawrence")
                "/x/space/wbi/arc/search" -> JSONObject().put("list",JSONObject().put("vlist",JSONArray())).put("page",JSONObject().put("count",0))
                "/x/relation/followings" -> {
                    if (offline.get()) throw java.io.IOException("isolated offline refresh")
                    val ids=if (request.url.queryParameter("pn")=="1") 1..20 else 21..23
                    JSONObject().put("total",23).put("list",JSONArray(ids.map {
                        JSONObject().put("mid",it).put("uname",if(it==21) "小鹿Lawrence" else if(it==22) "影视飓风" else if(it==23) "女流" else "关注用户$it").put("attribute",2)
                    }))
                }
                else -> error("Unexpected request: ${request.url.encodedPath}")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(JSONObject().put("code",0).put("data",data).toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        val memory=object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} }
        val http=BiliHttp(memory,client)
        runBlocking { http.acceptLogin("SESSDATA=fixture-only; bili_jct=fixture-only") }
        val cached=object: SecureStore { var value: ByteArray?=null; override fun load()=value; override fun save(bytes: ByteArray) { value=bytes }; override fun clear() { value=null } }
        lateinit var model: AppModel
        try {
            rule.runOnUiThread { model=ViewModelProvider(models,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(context,http,peopleStoreFactory={ cached }) as T
            })[AppModel::class.java] }
            rule.waitUntil(5000) { !model.restoring }
            rule.runOnUiThread { model.open(Route.People(false)) }
            rule.setContent { MainApp(model) }
            val field=rule.onNodeWithTag("people-search-field")
            field.performTextInput("law")
            rule.waitUntil(10000) { rule.onAllNodesWithText("小鹿Lawrence").fetchSemanticsNodes().isNotEmpty() }
            rule.onNodeWithText("小鹿Lawrence").assertIsDisplayed().assertHasClickAction()
            field.assertTextContains("law")
            rule.onNodeWithText("找到 1 个用户关注用户").assertIsDisplayed()
            rule.onNodeWithText("UP主名字补全").assertDoesNotExist()
            rule.onNodeWithText("小鹿Lawrence").performClick()
            rule.waitUntil(5000) { model.routes.lastOrNull() is Route.Creator }
            rule.runOnUiThread { model.back() }
            rule.onNodeWithTag("people-search-field").assertTextContains("law")
            rule.onNodeWithContentDescription("清空关注搜索").performClick()
            rule.onNodeWithText("关注用户1").assertIsDisplayed()
            field.performTextInput("NoSuchFollowedPerson")
            rule.onNodeWithText("没有匹配的关注用户，试试名字或拼音。").assertIsDisplayed()
            field.performTextReplacement("ysjf")
            rule.onNodeWithText("UP主名字补全").assertDoesNotExist()
            rule.onNodeWithText("影视飓风").assertIsDisplayed()
            field.performTextReplacement("xll")
            rule.onNodeWithText("小鹿Lawrence").assertIsDisplayed()
            field.performTextReplacement("nvliu")
            rule.onNodeWithText("女流").assertIsDisplayed()
            field.performTextReplacement("yingshijufeng")
            rule.onNodeWithText("影视飓风").assertIsDisplayed()
            assertNotNull(cached.value)
            offline.set(true)
            rule.runOnUiThread { models.clear(); model=ViewModelProvider(models,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(context,http,peopleStoreFactory={ cached }) as T
            })[AppModel::class.java] }
            rule.waitUntil(5000) { !model.restoring }
            rule.runOnUiThread { model.open(Route.People(false)); rule.activity.setContent { MainApp(model) } }
            rule.waitUntil(5000) { model.peopleSearch.complete }
            rule.onNodeWithTag("people-search-field").performTextInput("ysjf")
            rule.onNodeWithText("影视飓风").assertIsDisplayed()
            rule.waitUntil(5000) { model.peopleSearch.error!=null }
            rule.onNodeWithText("影视飓风").assertIsDisplayed()
            rule.runOnUiThread { model.update(null) }
            rule.waitUntil(5000) { cached.value==null }
            assertNull(model.peopleSearch.items)
            val orphan=SessionVault(context,"people-42")
            orphan.save(PeopleSearch.encode(42,listOf(User(7,"遗留名单",null))))
            assertNotNull(orphan.load())
            runBlocking { http.logout() }
            rule.runOnUiThread { models.clear(); model=ViewModelProvider(models,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(context,http,peopleStoreFactory={ cached }) as T
            })[AppModel::class.java] }
            rule.waitUntil(5000) { !model.restoring && !java.io.File(context.noBackupFilesDir,"people-42.enc").exists() }
            assertNull(orphan.load())
            assertTrue(requests.any { it.url.queryParameter("pn")=="2" })
            assertTrue(requests.all { it.method=="GET" })
        } finally { rule.runOnUiThread { models.clear() } }
    }
}

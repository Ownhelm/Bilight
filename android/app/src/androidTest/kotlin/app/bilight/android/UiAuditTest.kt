@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package app.bilight.android

import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.*
import app.bilight.android.downloads.*
import app.bilight.android.playback.PlaybackModel
import app.bilight.android.ui.MainApp
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Opt-in only: exercise production screens with local fixtures, never the connected phone/account. */
class UiAuditTest {
    @get:Rule val rule=createAndroidComposeRule<ComponentActivity>()
    @Test fun captureEveryReachableScreenAndStressState() {
        val arguments=InstrumentationRegistry.getArguments()
        assumeTrue(arguments.getString("uiAudit")=="true")
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish") && android.os.Build.MODEL.contains("sdk",ignoreCase=true)) { "UI audit fixtures must run only in the isolated emulator" }
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(SessionVault(app).load()==null) { "UI audit refuses to use an existing login" }
        val fixtures=UiAuditFixtures(app)
        val originalImages=SingletonImageLoader.get(app)
        SingletonImageLoader.setUnsafe(ImageLoader.Builder(app).components { add(OkHttpNetworkFetcherFactory(callFactory={ fixtures.client() })) }.build())
        val vault=object: SecureStore { var value: ByteArray?=null; override fun load()=value; override fun save(bytes: ByteArray) { value=bytes }; override fun clear() { value=null } }
        val http=BiliHttp(vault,fixtures.client())
        runBlocking { http.acceptLogin("SESSDATA=isolated-fixture; bili_jct=isolated-fixture") }
        SessionVault(app,"downloads-${fixtures.uid}").clear()
        val viewModels=ViewModelStore()
        lateinit var model: AppModel
        val prefix=arguments.getString("capturePrefix") ?: "default"
        check(Regex("^[a-z0-9-]+$").matches(prefix))
        val folder=File(app.filesDir,"ui-audit/$prefix").apply { mkdirs() }
        val captures=JSONArray()
        val scale=arguments.getString("fontScale")?.toFloat() ?: 1f
        val stress=arguments.getString("stress")=="true"
        fun idle() { rule.waitForIdle(); Thread.sleep(220); rule.waitForIdle() }
        fun capture(name: String) {
            idle()
            val bitmap=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            File(folder,"$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }; bitmap.recycle()
            val nodes=rule.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.Text),useUnmergedTree=true).fetchSemanticsNodes()
            val labels=nodes.map { node -> val rect=node.boundsInRoot; JSONObject().put("text",node.config[SemanticsProperties.Text].joinToString { it.text }).put("bounds",JSONArray(listOf(rect.left,rect.top,rect.right,rect.bottom))) }
            captures.put(JSONObject().put("name",name).put("labels",JSONArray(labels)))
            File(folder,"index.json").writeText(captures.toString(2))
        }
        fun open(route: Route) { rule.runOnIdle { model.showAccount=false; model.routes.clear(); model.open(route) }; idle() }
        fun click(text: String) { rule.onAllNodesWithText(text,useUnmergedTree=true).onFirst().performClick(); idle() }
        fun icon(description: String) { rule.onAllNodesWithContentDescription(description,useUnmergedTree=true).onFirst().performClick(); idle() }
        try {
            rule.runOnUiThread {
                rule.activity.enableEdgeToEdge()
                model=ViewModelProvider(viewModels,object: ViewModelProvider.Factory {
                    @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T = AppModel(app,http) { owner,route -> PlaybackModel(owner,route,fixtures.mediaClient()) } as T
                })[AppModel::class.java]
            }
            rule.waitUntil(5000) { !model.restoring }
            rule.setContent { CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density,scale)) { MainApp(model) } }
            if (arguments.getString("favoriteOnly")=="true") {
                val route=Route.Watch(fixtures.videos[0].bvid); open(route)
                rule.waitUntil(10000) { model.playback(route).detail!=null && model.playback(route).playback!=null && !model.playback(route).preparing }
                repeat(20) { index ->
                    icon("投币"); click("取消"); icon("收藏")
                    try { rule.waitUntil(5000) { rule.onAllNodesWithText("收藏到（1）").fetchSemanticsNodes().isNotEmpty() } }
                    catch (failure: Throwable) { capture("favorite-failed-$index"); throw failure }
                    click("取消")
                }
                capture("favorite-repeat-passed"); return
            }
            capture("01-home")
            rule.onNode(hasSetTextAction()).performClick(); capture("01a-home-keyboard"); androidx.test.espresso.Espresso.closeSoftKeyboard()
            rule.runOnIdle { model.keyword="旅行"; model.search() }; rule.waitUntil(5000) { !model.searchBusy }; capture("02-search-videos")
            click("UP主"); rule.waitUntil(5000) { !model.searchBusy }; capture("03-search-users")
            if (!stress) {
                fixtures.empty=true; rule.runOnIdle { model.search() }; rule.waitUntil(5000) { !model.searchBusy }; capture("04-search-empty")
                fixtures.empty=false; fixtures.blocked.add("/x/web-interface/wbi/search/type"); rule.runOnIdle { model.search() }; rule.waitUntil(5000) { !model.searchBusy }; capture("05-search-error")
                fixtures.blocked.clear()
            }
            rule.runOnIdle { model.searched=false; model.keyword=""; model.tab=1 }
            rule.waitUntil(5000) { model.feedLoaded && !model.feedBusy }
            val posts=fixtures.posts()
            rule.runOnIdle { model.following.add(posts[0]) }; capture("06-feed-photo-collapsed")
            if (!stress) { click("展开"); capture("07-feed-photo-expanded"); click("收起"); icon("查看第1张图片"); capture("08-photo-viewer"); icon("关闭图片") }
            for ((index,post) in posts.drop(1).withIndex()) {
                if (stress && index>0) break
                rule.runOnIdle { model.following.clear(); model.following.add(post) }; capture("09-feed-type-$index")
            }
            rule.runOnIdle { model.showAccount=true }; capture("10-account")
            if (arguments.getString("verifyFixes")=="true") { rule.onNodeWithText("退出登录").performScrollTo().assertIsDisplayed(); capture("10a-account-bottom") }
            rule.runOnIdle { model.showAccount=false }
            open(Route.People(false)); capture("11-followed-people")
            if (!stress) { open(Route.People(true)); capture("12-frequent-people") }
            open(Route.Creator(fixtures.creators[0])); capture("13-creator-videos")
            click("合集和列表"); capture("14-creator-collections")
            if (!stress) {
                open(Route.Catalog(fixtures.creators[0],Collection(201,fixtures.creators[0].mid,false,"旅行影像：在路上的每一个故事",fixtures.videos[0].cover,8))); capture("15-collection-videos")
            }
            open(Route.Favorites); capture("16-favorites-created")
            click("我收藏的"); capture("17-favorites-collected")
            if (!stress) { open(Route.Favorite(Folder(101,fixtures.uid,"电影、旅行与值得慢慢看的故事",28,true,true,50000,fixtures.videos[0].cover))); capture("18-folder-videos") }
            open(Route.History); capture("19-history")
            if (!stress) { open(Route.Dynamic(posts[0])); capture("20-dynamic-detail") }
            open(Route.Downloads); rule.waitUntil(5000) { model.downloads.ready }; capture("21-downloads-empty")
            val states=listOf(DownloadState.PAUSED,DownloadState.FAILED,DownloadState.DOWNLOADING,DownloadState.COMPLETED)
            rule.runOnIdle { states.forEachIndexed { i,state -> model.downloads.items.add(DownloadRecord("audit-$i",fixtures.videos[i],Part(30001,1,"正片：一段完整的旅行记录",120),80,"1080P 高清",state,32,100,if(state==DownloadState.FAILED) "连接中断，请检查网络后继续。" else null)) } }
            capture("22-downloads-states")
            if (!stress) { icon("删除下载"); capture("23-download-delete-confirm"); click("取消") }
            val route=Route.Watch(fixtures.videos[0].bvid)
            open(route)
            rule.waitUntil(10000) { model.playback(route).detail!=null && model.playback(route).playback!=null && !model.playback(route).preparing }
            rule.runOnIdle { model.playback(route).controlsVisible=true }; capture("24-video-inline")
            run {
                icon("投币"); capture("25-coin-dialog"); click("取消")
                icon("收藏")
                try { rule.waitUntil(5000) { rule.onAllNodesWithText("收藏到（1）").fetchSemanticsNodes().isNotEmpty() } }
                catch (failure: Throwable) {
                    capture("26-favorite-unexpected")
                    File(folder,"threads.txt").writeText(Thread.getAllStackTraces().entries.filter { (thread,_) -> thread.name=="main" || thread.name.contains("OkHttp") || thread.name.contains("DefaultDispatcher") }.joinToString("\n\n") { (thread,stack) -> thread.name+" "+thread.state+"\n"+stack.joinToString("\n") })
                    rule.mainClock.advanceTimeBy(500); rule.waitForIdle()
                    capture("26-favorite-after-idle")
                    throw failure
                }
                capture("26-favorite-dialog")
                rule.onNode(hasSetTextAction()).performClick().performTextInput("旅行影像")
                capture("26a-favorite-keyboard")
                if (arguments.getString("verifyFixes")=="true") { rule.onNodeWithText("取消").assertIsDisplayed(); rule.onNode(hasSetTextAction()).assertIsDisplayed() }
                androidx.test.espresso.Espresso.closeSoftKeyboard(); click("取消")
                icon("下载"); capture("27-download-options"); rule.runOnIdle { }; androidx.test.espresso.Espresso.pressBack(); idle()
            }
            rule.runOnIdle { model.playback(route).settings=true }; capture("28-player-settings")
            rule.runOnIdle { model.playback(route).danmaku(true) }; capture("29-danmaku-settings")
            rule.onAllNodes(hasScrollAction()).onLast().performScrollToNode(hasText("弹幕占比")); capture("30-danmaku-area")
            if (arguments.getString("verifyFixes")=="true") { rule.onAllNodes(hasScrollAction()).onLast().performScrollToNode(hasText("100%")); rule.onNodeWithText("100%").assertIsDisplayed(); capture("30a-danmaku-opacity") }
            rule.runOnIdle { model.playback(route).settings=false }
            if (!stress) {
                fixtures.portrait=true
                val vertical=Route.Watch(fixtures.videos[1].bvid)
                open(vertical); rule.waitUntil(10000) { model.playback(vertical).playback!=null && !model.playback(vertical).preparing }
                rule.runOnIdle { model.playback(vertical).controlsVisible=true }; icon("全屏"); rule.waitUntil(5000) { model.playback(vertical).fullscreen }; capture("30b-portrait-fullscreen")
                rule.onAllNodesWithContentDescription("退出全屏").onLast().performClick(); rule.waitUntil(5000) { !model.playback(vertical).fullscreen }; capture("30c-portrait-exit")
                rule.runOnIdle { model.playback(vertical).controlsVisible=true }; icon("全屏")
                rule.onNodeWithContentDescription("视频画面").performTouchInput { swipe(start=androidx.compose.ui.geometry.Offset(centerX,height*.25f),end=androidx.compose.ui.geometry.Offset(centerX,height*.75f),durationMillis=300) }
                rule.waitUntil(5000) { !model.playback(vertical).fullscreen }; capture("30d-portrait-swipe-exit")
                fixtures.portrait=false; fixtures.blocked.add("/x/player/wbi/playurl")
                val failed=Route.Watch(fixtures.videos[2].bvid); open(failed); rule.waitUntil(5000) { model.playback(failed).error!=null }; capture("30e-video-error")
                fixtures.blocked.clear()
            }
            rule.runOnIdle { model.error="连接B站超时，请检查网络后重试。" }; capture("31-global-error")
            rule.runOnIdle { model.error=null; model.routes.clear(); model.tab=1; model.update(null) }; capture("32-following-logged-out")
            if (!stress) {
                open(Route.Downloads); capture("33-downloads-logged-out")
                fixtures.empty=true; rule.runOnIdle { model.update(http.user) }; open(Route.People(false)); capture("34-people-empty"); rule.onNodeWithText("暂无内容").assertIsDisplayed()
                open(Route.Favorites); capture("35-favorites-empty"); rule.onNodeWithText("暂无收藏夹").assertIsDisplayed()
                open(Route.History); capture("36-history-empty")
            }
            assertTrue(fixtures.requests.none { it.contains("recommend") || it.contains("popular") || it.contains("hot") })
            File(folder,"requests.json").writeText(JSONArray(fixtures.requests).toString(2))
        } finally {
            File(folder,"requests.json").writeText(JSONArray(fixtures.requests).toString(2))
            rule.runOnIdle { model.downloads.pauseAll(); model.downloads.account(null); viewModels.clear() }
            SingletonImageLoader.setUnsafe(originalImages)
            SessionVault(app,"downloads-${fixtures.uid}").clear()
        }
    }
}

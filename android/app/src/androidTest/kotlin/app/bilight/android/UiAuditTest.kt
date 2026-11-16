@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package app.bilight.android

import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
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
import java.util.concurrent.CountDownLatch

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
            if (arguments.getString("dynamicCommentsOnly")=="true") {
                fixtures.dynamicCommentAudit=true
                open(Route.Dynamic(fixtures.posts().first().copy(commentId=null,commentType=0)))
                rule.waitUntil(5000) { rule.onAllNodesWithTag("video-comment-open").fetchSemanticsNodes().isNotEmpty() }
                rule.onNodeWithTag("video-comment-open").assertIsEnabled().performClick()
                rule.onNodeWithTag("video-comment-text").assertIsDisplayed()
                rule.onNodeWithContentDescription("关闭评论窗口").performTouchInput { click(percentOffset(0.5f,0.15f)) }
                rule.onNodeWithTag("video-comment-text").assertDoesNotExist()
                rule.onNode(hasScrollAction()).performScrollToNode(hasTestTag("comment-expand-301"))
                rule.onNodeWithTag("comment-expand-301").performClick()
                rule.waitUntil(5000) { rule.onAllNodesWithTag("video-comment-reply-302").fetchSemanticsNodes().isNotEmpty() }
                rule.onNodeWithTag("video-comment-like-302").assertIsEnabled()
                rule.onNodeWithTag("video-comment-reply-302").assertIsEnabled().performClick()
                rule.onNodeWithText("回复 ${fixtures.creators[2].name}").assertIsDisplayed()
                rule.onNodeWithTag("video-comment-text").assertIsDisplayed()
                rule.onNodeWithText("取消").performClick()
                rule.onNodeWithTag("video-comment-text").assertDoesNotExist()
                assertFalse(fixtures.requests.any { it.contains("/x/player/") })
                return
            }
            if (arguments.getString("darkFollowingOnly") == "true") {
                val previousDark = model.darkAppearance
                val heldRead = CountDownLatch(1)
                val darkBars = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
                fun darkCapture(name: String) {
                    rule.onNodeWithTag("following-header-divider").assertDoesNotExist()
                    capture(name)
                    val bitmap = android.graphics.BitmapFactory.decodeFile(File(folder, "$name.png").absolutePath)
                    try {
                        val surface = android.graphics.Color.rgb(21, 22, 28)
                        assertEquals("The following surface must stay dark in $name", surface, bitmap.getPixel(bitmap.width / 8, bitmap.height / 2))
                    } finally { bitmap.recycle() }
                }
                try {
                    rule.runOnIdle {
                        if (!model.darkAppearance) model.toggleAppearance()
                        rule.activity.enableEdgeToEdge(statusBarStyle = darkBars, navigationBarStyle = darkBars)
                        model.enterFollowing()
                    }
                    rule.waitUntil(5000) { model.feedLoaded && !model.feedBusy }
                    rule.onNodeWithText("暂无关注动态").assertIsDisplayed()
                    darkCapture("01-empty")

                    fixtures.feedReadGate = heldRead
                    fixtures.blocked.add("/x/polymer/web-dynamic/v1/feed/all")
                    rule.runOnIdle { model.enterFollowing() }
                    rule.onNodeWithContentDescription("正在刷新关注动态").assertIsDisplayed()
                    darkCapture("02-refresh")
                    heldRead.countDown()
                    rule.waitUntil(5000) { model.feedError != null && !model.feedBusy }
                    rule.onNodeWithText("重试").assertIsDisplayed()
                    darkCapture("03-error")

                    rule.runOnIdle { model.following.add(fixtures.posts().first()) }
                    rule.onNodeWithTag("following-header-divider").assertExists()
                    rule.runOnIdle { model.update(null) }
                    rule.onNodeWithText("登录后查看关注动态").assertIsDisplayed()
                    darkCapture("04-signed-out")
                } finally {
                    heldRead.countDown()
                    fixtures.feedReadGate = null
                    rule.runOnIdle { if (model.darkAppearance != previousDark) model.toggleAppearance() }
                }
                return
            }
            if (arguments.getString("creatorWatchLaterOnly") == "true") {
                val creator = fixtures.creators.first()
                val video = fixtures.videos.first { it.owner.mid == creator.mid }
                val tag = "watch-later-${video.bvid}"
                val button = rule.onNodeWithTag(tag)
                fun state(saved: Boolean) {
                    rule.waitUntil(5000) { model.watchLater.saved(video) == saved && rule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty() }
                    button.assertIsDisplayed().assert(SemanticsMatcher.expectValue(
                        SemanticsProperties.StateDescription, if (saved) "已加入" else "未加入",
                    ))
                }
                val homepage = Route.Creator(creator)
                open(homepage)
                state(false)
                button.performClick()
                state(true)
                rule.runOnIdle { assertEquals(homepage, model.routes.last()) }

                click("合集和列表")
                click("旅行影像：在路上的每一个故事")
                state(true)
                button.performClick()
                state(false)
                rule.runOnIdle {
                    val group = model.routes.last() as Route.Catalog
                    assertFalse(group.collection.series)
                    model.back()
                }

                click("创作笔记与摄影基础")
                state(false)
                button.performClick()
                state(true)
                rule.runOnIdle { assertTrue((model.routes.last() as Route.Catalog).collection.series) }
                open(Route.WatchLater)
                rule.waitUntil(5000) { model.watchLater.items.any { it.aid == video.aid } }
                rule.onNodeWithText(video.title).assertIsDisplayed()
                assertEquals(2, fixtures.requests.count { it == "POST /x/v2/history/toview/add" })
                assertEquals(1, fixtures.requests.count { it == "POST /x/v2/history/toview/del" })
                return
            }
            if (arguments.getString("watchLaterNoticeOnly") == "true") {
                val video = fixtures.videos.first()
                val tag = "watch-later-${video.bvid}"
                open(Route.Watch(video.bvid))
                val button = rule.onNodeWithTag(tag)
                rule.waitUntil(5000) { model.watchLater.saved(video) == false }
                fun toggle() {
                    if (rule.onAllNodesWithTag(tag).fetchSemanticsNodes().isEmpty()) {
                        rule.onNodeWithContentDescription("视频画面").performClick()
                    }
                    button.assertIsDisplayed().assertIsEnabled().performClick()
                }
                fun notice(text: String) {
                    rule.waitUntil(3000) { rule.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
                    rule.onNodeWithText(text).assertIsDisplayed()
                }
                toggle()
                rule.waitUntil(5000) { model.watchLater.saved(video) == true && !model.watchLater.pending(video) }
                notice("已添加到稍后再看")
                capture("watch-later-added")
                toggle()
                rule.waitUntil(5000) { model.watchLater.saved(video) == false && !model.watchLater.pending(video) }
                notice("已从稍后再看移除")
                capture("watch-later-removed")
                rule.waitUntil(5000) { rule.onAllNodesWithTag("watch-later-notification").fetchSemanticsNodes().isEmpty() }
                assertEquals(1, fixtures.requests.count { it == "POST /x/v2/history/toview/add" })
                assertEquals(1, fixtures.requests.count { it == "POST /x/v2/history/toview/del" })
                open(Route.WatchLater)
                rule.waitUntil(5000) { model.watchLater.loaded && !model.watchLater.loading }
                rule.onNodeWithContentDescription("移出稍后再看").assertIsDisplayed().assertHasClickAction()
                capture("watch-later-list")
                return
            }
            if (arguments.getString("watchLaterOnly") == "true") {
                val video = fixtures.videos.first()
                rule.runOnIdle { model.keyword = video.title.take(6); model.search() }
                rule.waitUntil(5000) { !model.searchBusy && model.watchLater.saved(video) == false }
                val button = rule.onNodeWithTag("watch-later-${video.bvid}")
                button.assertIsDisplayed().performClick()
                rule.waitUntil(5000) { model.watchLater.saved(video) == true }
                rule.onNodeWithText("已添加到稍后再看").assertIsDisplayed()
                rule.runOnIdle { assertTrue("The cover action must not open playback", model.routes.isEmpty()); model.showAccount = true }
                val favorites = rule.onNodeWithText("我的收藏").getUnclippedBoundsInRoot()
                val watchLater = rule.onNodeWithText("稍后再看").getUnclippedBoundsInRoot()
                val downloads = rule.onNodeWithText("我的下载").getUnclippedBoundsInRoot()
                assertTrue(favorites.top < watchLater.top && watchLater.top < downloads.top)
                click("稍后再看")
                rule.waitUntil(5000) { model.watchLater.items.firstOrNull()?.aid == video.aid && !model.watchLater.loading }
                assertEquals(Route.Watch(video.bvid, progress = 31, cid = 30002), model.watchLater.items.first().route)
                rule.onAllNodesWithContentDescription("移出稍后再看").onFirst().performClick()
                rule.waitUntil(5000) { model.watchLater.saved(video) == false }
                rule.onNodeWithText("撤销").performClick()
                rule.waitUntil(5000) { model.watchLater.saved(video) == true }
                capture("watch-later-list")
                val repost = fixtures.posts().first { it.original?.video?.aid == video.aid }
                open(Route.Dynamic(repost))
                button.assertIsDisplayed().assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "已加入"))
                capture("watch-later-repost")
                assertEquals(2, fixtures.requests.count { it == "POST /x/v2/history/toview/add" })
                assertEquals(1, fixtures.requests.count { it == "POST /x/v2/history/toview/del" })
                open(Route.WatchLater)
                rule.waitUntil(5000) { model.watchLater.items.size == 2 && !model.watchLater.loading }
                click("管理")
                click(video.title)
                click(fixtures.videos.last().title)
                click("移除")
                rule.onNode(hasText("移除") and hasAnyAncestor(isDialog())).performClick()
                rule.waitUntil(5000) { model.watchLater.items.isEmpty() && !model.watchLater.writing }
                rule.onNodeWithText("暂无稍后再看的视频").assertIsDisplayed()
                val removal = fixtures.requests.indexOf("POST /x/v2/history/toview/v2/dels")
                assertTrue(removal >= 0 && fixtures.requests.lastIndexOf("GET /x/v2/history/toview/web") > removal)
                return
            }
            if (arguments.getString("searchFilterOnly") == "true") {
                val wasEnabled = model.searchTitleOnly
                try {
                    rule.runOnIdle { model.keyword = "去了一趟"; model.search() }
                    rule.waitUntil(5000) { !model.searchBusy }
                    if (!wasEnabled) {
                        rule.onNodeWithTag("video-search-filter").performClick()
                        click("仅标题匹配")
                    }
                    rule.onNodeWithTag("video-search-filter").performClick()
                    rule.onNodeWithText("只保留标题包含所有搜索词的视频", useUnmergedTree = true).assertIsDisplayed()
                    capture("search-filter-open")
                } finally {
                    rule.runOnIdle { if (model.searchTitleOnly != wasEnabled) model.toggleSearchTitleOnly() }
                }
                return
            }
            if (arguments.getString("peopleResultsOnly")=="true") {
                open(Route.People(false)); rule.waitUntil(10000) { model.peopleSearch.complete }
                val field=rule.onNodeWithTag("people-search-field")
                field.performTextInput("a"); field.performImeAction()
                rule.onNodeWithText("找到 2 个用户关注用户").assertIsDisplayed()
                rule.onNodeWithText("UP主名字补全").assertDoesNotExist()
                rule.onNodeWithText("小鹿Lawrence").assertIsDisplayed().assertHasClickAction()
                rule.onNodeWithText("超Carry的柴西").assertIsDisplayed().assertHasClickAction()
                capture("android-search")
                return
            }
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
            click("UP 主"); rule.waitUntil(5000) { !model.searchBusy }; capture("03-search-users")
            if (!stress) {
                fixtures.empty=true; rule.runOnIdle { model.search() }; rule.waitUntil(5000) { !model.searchBusy }; capture("04-search-empty")
                fixtures.empty=false; fixtures.blocked.add("/x/web-interface/wbi/search/type"); rule.runOnIdle { model.search() }; rule.waitUntil(5000) { !model.searchBusy }; capture("05-search-error")
                fixtures.blocked.clear()
            }
            val tabRole = SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab)
            val searchTab = rule.onNode(hasText("搜索") and tabRole)
            val followingTab = rule.onNode(hasText("关注") and tabRole)
            searchTab.performClick()
            rule.onNodeWithText("搜你所想，看你所选").assertIsDisplayed()
            rule.runOnIdle {
                assertEquals("", model.keyword)
                assertFalse(model.searchUsers)
                assertNull(model.searchError)
                model.keyword = "旅行"
                model.search()
            }
            rule.waitUntil(5000) { !model.searchBusy }
            rule.onNodeWithText("UP 主").assertIsDisplayed()
            followingTab.performClick()
            rule.onNodeWithText("我的关注").assertIsDisplayed()
            searchTab.performClick()
            rule.onNodeWithText("搜你所想，看你所选").assertIsDisplayed()
            rule.runOnIdle { assertEquals("", model.keyword) }
            if (arguments.getString("searchNavigationOnly") == "true") return
            followingTab.performClick()
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

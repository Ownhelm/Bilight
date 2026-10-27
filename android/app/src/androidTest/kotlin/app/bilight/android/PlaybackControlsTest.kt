@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package app.bilight.android

import android.content.Context
import android.view.ViewGroup
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.media3.common.Player
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.*
import app.bilight.android.core.Route
import app.bilight.android.playback.PlaybackModel
import app.bilight.android.ui.MainApp
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Opt-in native DASH/Compose tests. Synthetic media is generated outside Git and staged in cache. */
class PlaybackControlsTest {
    @get:Rule val rule=createAndroidComposeRule<MainActivity>()
    private fun capture(name: String) {
        rule.waitForIdle()
        val root=File(ApplicationProvider.getApplicationContext<Context>().filesDir,"player-controls-acceptance").apply { mkdirs() }
        val bitmap=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        try { File(root,"$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) } } finally { bitmap.recycle() }
    }
    private fun await(message: String,condition: () -> Boolean) {
        try { rule.waitUntil(7000) { var result=false; rule.runOnUiThread { result=condition() }; result } }
        catch (e: AssertionError) { throw AssertionError(message,e) }
    }
    private fun fixture(test: (Fixture,PlaybackModel) -> Unit) {
        assumeTrue(InstrumentationRegistry.getArguments().getString("playbackControls")=="true")
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish") && SessionVault(app).load()==null)
        rule.runOnUiThread { rule.activity.findViewById<ViewGroup>(android.R.id.content).removeAllViews() }
        val preferences=app.getSharedPreferences("playback-preferences",Context.MODE_PRIVATE)
        val saved=HashMap(preferences.all)
        preferences.edit().clear().putInt("quality",80).commit()
        val f=Fixture(app)
        try {
            await("The isolated account did not restore") { !f.owner.restoring }
            val route=Route.Watch("BV12qnt6VEM1")
            rule.runOnIdle { f.owner.open(route) }
            rule.setContent { MainApp(f.owner) }
            lateinit var model: PlaybackModel
            rule.runOnIdle { model=f.owner.playback(route) }
            await("The native DASH fixture did not render its first frame") { model.hasFrame && model.player.playbackState==Player.STATE_READY }
            rule.runOnIdle {
                model.player.pause(); model.seek(15000)
                assertEquals("Seeking a ready native player failed before a quality switch (cached duration=${model.duration}, native duration=${model.player.duration})",15000L,model.player.currentPosition)
                model.speed(1.5f); model.controlsVisible=true
            }
            test(f,model)
        } finally {
            f.gate?.countDown(); rule.runOnUiThread { f.store.clear() }; f.close()
            preferences.edit().clear().apply { saved.forEach { (key,value) -> when(value) {
                is Int -> putInt(key,value); is Boolean -> putBoolean(key,value); is Float -> putFloat(key,value)
                is String -> putString(key,value); is Long -> putLong(key,value)
            } } }.commit()
        }
    }
    @Test fun reselectingTheCurrentQualityCancelsAPendingDifferentQuality() = fixture { f,model ->
        val original=model.player
        rule.onNodeWithContentDescription("全屏").performClick()
        await("Portrait fullscreen did not open") { model.fullscreen && model.portraitFullscreen }
        f.gate=CountDownLatch(1)
        rule.runOnIdle { model.chooseQuality(120) }
        await("The delayed higher-quality request did not begin") { f.qualities.contains(120) }
        rule.runOnIdle { model.chooseQuality(80) }
        f.gate!!.countDown()
        await("The final quality selection remained stuck loading") { !model.preparing && model.player.playbackState==Player.STATE_READY }
        rule.runOnIdle {
            assertEquals("A stale quality response overrode the user's last selection",80,model.playback!!.quality)
            assertSame(original,model.player); assertTrue(model.fullscreen)
            assertEquals(15000L,model.player.currentPosition); assertFalse(model.player.playWhenReady)
            assertEquals(1.5f,model.player.playbackParameters.speed)
        }
        rule.runOnIdle { model.settings=true }
        capture("01-last-quality")
    }
    @Test fun nativeQualitySwitchAndDoubleTapZonesPreservePlaybackAndFullscreen() = fixture { _,model ->
        val original=model.player
        rule.onNodeWithContentDescription("全屏").performClick()
        await("Portrait fullscreen did not open") { model.fullscreen }
        rule.runOnIdle { model.chooseQuality(120) }
        await("The native DASH quality switch did not finish") { model.playback?.quality==120 && model.player.playbackState==Player.STATE_READY }
        rule.runOnIdle {
            assertSame(original,model.player); assertTrue(model.fullscreen); assertFalse(model.player.playWhenReady)
            assertEquals(15000L,model.player.currentPosition); assertEquals(1.5f,model.player.playbackParameters.speed)
        }
        fun doubleTap(fraction: Float) { rule.onNodeWithContentDescription("视频画面").performTouchInput { doubleClick(Offset(width*fraction,height*.5f)) } }
        doubleTap(.2f)
        rule.runOnIdle { assertEquals(5000L,model.player.currentPosition); assertFalse(model.player.playWhenReady) }
        doubleTap(.8f)
        rule.runOnIdle { assertEquals(15000L,model.player.currentPosition); assertFalse(model.player.playWhenReady) }
        doubleTap(.5f)
        await("The middle double tap did not resume playback") { model.player.playWhenReady && model.player.isPlaying }
        doubleTap(.5f)
        rule.runOnIdle { assertFalse(model.player.playWhenReady) }
        rule.runOnIdle { model.seek(1000) }; doubleTap(.2f)
        rule.runOnIdle { assertEquals(0L,model.player.currentPosition) }
        rule.runOnIdle { model.seek(model.duration-1000) }; doubleTap(.8f)
        rule.runOnIdle {
            // Media3 clamps a seek at the exclusive end to the final millisecond.
            assertTrue(model.player.currentPosition in model.duration-1..model.duration); assertFalse(model.player.playWhenReady)
            assertSame(original,model.player); assertTrue(model.fullscreen)
        }
        if (!model.controlsVisible) rule.onNodeWithContentDescription("视频画面").performTouchInput { click(center) }
        rule.onNodeWithContentDescription("播放设置").performClick()
        rule.onNodeWithText("清晰度").assertIsDisplayed()
        rule.runOnIdle { assertFalse("Opening settings changed paused state",model.player.playWhenReady) }
        capture("02-playback-settings")
    }
    private inner class Fixture(val app: BilightApplication) {
        val store=ViewModelStore()
        val qualities=CopyOnWriteArrayList<Int>()
        @Volatile var gate: CountDownLatch?=null
        private val root=File(app.cacheDir,"playback-controls")
        private val tracks=JSONArray(File(root,"tracks.json").readText()).objects()
        private val api=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); val path=request.url.encodedPath
            val text=when(path) {
                "/x/web-interface/nav" -> """{"code":0,"data":{"isLogin":false,"wbi_img":{"img_url":"https://i0.hdslb.com/${"a".repeat(32)}.png","sub_url":"https://i0.hdslb.com/${"b".repeat(32)}.png"}}}"""
                "/x/web-interface/wbi/view" -> """{"code":0,"data":{"bvid":"BV12qnt6VEM1","aid":42,"title":"原生播放器交互回归","duration":32,"owner":{"mid":42,"name":"隔离测试"},"pages":[{"cid":43,"page":1,"part":"正片","duration":32,"dimension":{"width":128,"height":224}}],"stat":{}}}"""
                "/x/player/wbi/playurl" -> {
                    val quality=request.url.queryParameter("qn")!!.toInt(); qualities+=quality
                    if (quality==120) check(gate?.await(5,TimeUnit.SECONDS)!=false)
                    JSONObject().put("code",0).put("data",JSONObject().put("accept_quality",JSONArray(listOf(120,80))).put("accept_description",JSONArray(listOf("高测试档","低测试档"))).put("dash",JSONObject().put("duration",32).put("video",JSONArray(tracks.filter { it.optInt("id") in listOf(80,120) })).put("audio",JSONArray(tracks.filter { it.optInt("id")==30280 })))).toString()
                }
                "/x/player/wbi/v2" -> """{"code":0,"data":{"subtitle":{"subtitles":[]}}}"""
                "/x/v2/reply/wbi/main" -> """{"code":0,"data":{"cursor":{"is_end":true,"all_count":0},"replies":[]}}}"""
                "/x/relation" -> """{"code":0,"data":{"attribute":0}}"""
                else -> error("Unexpected isolated request: $path")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(text.toResponseBody("application/json".toMediaType())).build()
        }.build()
        private val media=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); check(request.url.host=="audit.bilivideo.com")
            val bytes=File(root,request.url.pathSegments.last()).readBytes()
            val range=request.header("Range")?.removePrefix("bytes=")?.split('-')
            val start=range?.getOrNull(0)?.toIntOrNull() ?: 0
            val end=(range?.getOrNull(1)?.toIntOrNull() ?: bytes.lastIndex).coerceAtMost(bytes.lastIndex)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(if(range==null) 200 else 206).message("OK")
                .header("Content-Range","bytes $start-$end/${bytes.size}").body(bytes.copyOfRange(start,end+1).toResponseBody((if(request.url.encodedPath.endsWith(".m4a")) "audio/mp4" else "video/mp4").toMediaType())).build()
        }.build()
        val owner: AppModel
        init {
            val http=BiliHttp(object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} },api)
            lateinit var value: AppModel
            rule.runOnUiThread { value=ViewModelProvider(store,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) { a,r -> PlaybackModel(a,r,media) } as T
            })[AppModel::class.java] }
            owner=value
        }
        fun close() { api.dispatcher.cancelAll(); media.dispatcher.cancelAll() }
    }
}

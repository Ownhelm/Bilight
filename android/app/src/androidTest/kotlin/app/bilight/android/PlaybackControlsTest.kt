@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package app.bilight.android

import android.content.Context
import android.media.AudioManager
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.media3.common.Player
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.pressBack
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
import kotlin.math.roundToInt

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
        val isolatedDeviceBuild=app.packageName=="app.bilight.android.gestureverification"
        check((android.os.Build.HARDWARE in listOf("ranchu","goldfish") || isolatedDeviceBuild) && SessionVault(app).load()==null)
        rule.waitForIdle()
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
    @Test fun fullscreenSeekBarHasItsOwnRowAndDragsAcrossItsWidth() = fixture { _,model ->
        val original=model.player
        rule.onNodeWithContentDescription("全屏").performClick()
        await("Portrait fullscreen did not open") { model.fullscreen && model.portraitFullscreen }
        fun checkSeekBar(name: String) {
            rule.runOnIdle { model.controlsVisible=true }
            val slider=rule.onNodeWithContentDescription("播放进度")
            val bounds=slider.getUnclippedBoundsInRoot()
            val play=rule.onNodeWithContentDescription("播放").getUnclippedBoundsInRoot()
            val exit=rule.onAllNodesWithContentDescription("退出全屏").fetchSemanticsNodes().maxBy { it.boundsInRoot.left }
            val settings=rule.onNodeWithContentDescription("播放设置").getUnclippedBoundsInRoot()
            val density=rule.activity.resources.displayMetrics.density
            assertTrue("The seek bar must span over the lower control row",bounds.left.value<play.right.value && bounds.right.value>exit.boundsInRoot.left/density)
            assertTrue("The seek bar must not share the play-button row",bounds.bottom.value<=play.top.value+2f)
            assertTrue("Settings must appear directly to the left of fullscreen",settings.right.value<=exit.boundsInRoot.left/density+8f)
            assertEquals("Settings and play must share the lower controls row",play.top.value,settings.top.value,2f)
            slider.performTouchInput { swipe(Offset(width*.08f,centerY),Offset(width*.92f,centerY),600) }
            rule.runOnIdle {
                assertEquals("Full-width dragging did not seek near the right edge",model.duration*.92,model.player.currentPosition.toDouble(),model.duration*.06)
                assertSame(original,model.player); assertTrue(model.fullscreen)
                assertFalse(model.player.playWhenReady); assertEquals(1.5f,model.player.playbackParameters.speed)
            }
            slider.performTouchInput { swipe(Offset(width*.92f,centerY),Offset(width*.08f,centerY),600) }
            rule.runOnIdle { assertEquals("Full-width dragging did not seek near the left edge",model.duration*.08,model.player.currentPosition.toDouble(),model.duration*.06) }
            capture(name)
            rule.onNodeWithContentDescription("播放设置").performClick()
            rule.onNodeWithText("清晰度").assertIsDisplayed()
            rule.runOnIdle { assertSame(original,model.player); assertFalse(model.player.playWhenReady); model.settings=false }
        }
        checkSeekBar("03-portrait-seek-width")
        rule.runOnIdle {
            model.portraitFullscreen=false
            rule.activity.requestedOrientation=android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            model.controlsVisible=true
        }
        await("Landscape fullscreen did not open") { rule.activity.resources.configuration.orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE }
        checkSeekBar("04-landscape-seek-width")
    }
    @Test fun settingsUseConsistentTextAndPreserveChoicesBetweenPlayerLayouts() = fixture { _, model ->
        val original = model.player
        val switch = rule.onNode(hasText("弹幕") and SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Switch))

        fun scrollTo(label: String) {
            rule.onAllNodes(hasScrollAction()).onLast().performScrollToNode(hasText(label))
        }
        fun assertTextStyle(label: String, size: TextUnit = 14.sp, weight: FontWeight = FontWeight.Normal) {
            scrollTo(label)
            val layout = mutableListOf<TextLayoutResult>()
            rule.onNodeWithText(label, useUnmergedTree = true).assertIsDisplayed()
                .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { assertTrue(it(layout)) }
            val style = layout.single().layoutInput.style
            assertEquals("Wrong font size for $label", size, style.fontSize)
            assertEquals("Wrong font weight for $label", weight, style.fontWeight)
            if (weight == FontWeight.Normal) assertEquals("Wrong line height for $label", 20.sp, style.lineHeight)
        }
        fun openSettings() {
            rule.runOnIdle { model.controlsVisible = true }
            rule.onNodeWithContentDescription("播放设置").performClick()
            assertTextStyle("播放设置", 20.sp, FontWeight.SemiBold)
        }
        fun closeSettings() {
            pressBack()
            await("Back did not dismiss playback settings") { !model.settings }
        }
        fun assertSwitchHeight() {
            scrollTo("弹幕")
            val bounds = switch.getUnclippedBoundsInRoot()
            assertTrue("The full danmaku switch row must be at least 48dp high", bounds.bottom.value - bounds.top.value >= 47.9f)
        }
        fun assertSamePlayback() {
            rule.runOnIdle {
                assertSame(original, model.player)
                assertFalse(model.player.playWhenReady)
                assertEquals(15000L, model.player.currentPosition)
                assertEquals(1.5f, model.player.playbackParameters.speed)
            }
        }

        openSettings()
        listOf("清晰度", "低测试档", "倍速", "1.5×", "字幕", "暂无可用字幕", "弹幕").forEach { assertTextStyle(it) }
        assertSwitchHeight()
        switch.assertIsOff()
        rule.onNodeWithText("字号").assertDoesNotExist()
        switch.performClick().assertIsOn()
        listOf("字号", "小", "标准", "大", "弹幕占比", "1/2", "不透明度", "75%").forEach { assertTextStyle(it) }
        scrollTo("标准")
        rule.onNodeWithText("标准").assertIsSelected()
        rule.onNodeWithText("大").performClick().assertIsSelected()
        rule.runOnIdle { assertEquals(24, model.danmakuFont) }
        assertSamePlayback()
        closeSettings()

        rule.runOnIdle { model.controlsVisible = true }
        rule.onNodeWithContentDescription("全屏").performClick()
        await("Portrait fullscreen did not open") { model.fullscreen && model.portraitFullscreen }
        openSettings()
        assertSwitchHeight()
        assertTextStyle("大")
        rule.onNodeWithText("大").assertIsSelected()
        assertSamePlayback()
        closeSettings()

        rule.runOnIdle {
            model.portraitFullscreen = false
            rule.activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        await("Landscape fullscreen did not open") {
            model.fullscreen && rule.activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
        }
        openSettings()
        assertSwitchHeight()
        assertTextStyle("大")
        rule.onNodeWithText("大").assertIsSelected()
        assertSamePlayback()
        closeSettings()
    }
    @Test fun sensorRotationWaitsForStablePostures() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("sensorRotation")=="true")
        fixture { f,model ->
            val directory=File(f.app.cacheDir,"playback-rotation").apply { mkdirs() }
            val stage=File(directory,"stage")
            val ack=File(directory,"ack")
            val original=model.player
            fun inject(name: String) {
                stage.writeText(name)
                rule.waitUntil(7000) { runCatching { ack.readText()==name }.getOrDefault(false) }
            }
            fun landscape() = rule.activity.resources.configuration.orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE
            fun remainsInFullscreen(expected: Boolean) {
                val until=android.os.SystemClock.elapsedRealtime()+650
                while (android.os.SystemClock.elapsedRealtime()<until) {
                    rule.runOnUiThread { assertEquals(expected,model.fullscreen); assertEquals(expected,landscape()) }
                    Thread.sleep(30)
                }
            }
            try {
                inject("slight-left"); remainsInFullscreen(false)
                inject("brief-left"); remainsInFullscreen(false)
                inject("stable-left")
                await("A sustained left tilt did not enter landscape fullscreen") { model.fullscreen && landscape() }
                var left=0
                rule.runOnIdle { left=rule.activity.display!!.rotation }
                inject("stable-right")
                await("The opposite tilt did not flip the fullscreen window") { model.fullscreen && landscape() && rule.activity.display!!.rotation!=left }
                inject("slight-upright"); remainsInFullscreen(true)
                inject("brief-upright-flat"); remainsInFullscreen(true)
                inject("stable-upright")
                await("A sustained upright posture did not restore the embedded page") { !model.fullscreen && !landscape() }

                inject("stable-left-again")
                await("Landscape did not re-enter after a completed return") { model.fullscreen && landscape() }
                rule.runOnIdle { model.controlsVisible=true }
                rule.onAllNodesWithContentDescription("退出全屏").onLast().performClick()
                await("Manual exit did not return to the embedded page") { !model.fullscreen && !landscape() }
                inject("unstable-rearm"); remainsInFullscreen(false)
                inject("stable-rearm"); remainsInFullscreen(false)
                inject("stable-right-after-rearm")
                await("A confirmed upright posture did not re-enable auto-entry") { model.fullscreen && landscape() }
                rule.runOnIdle {
                    assertSame(original,model.player); assertFalse(model.player.playWhenReady)
                    assertEquals(15000L,model.player.currentPosition); assertEquals(1.5f,model.player.playbackParameters.speed)
                }
            } finally { stage.delete(); ack.delete() }
        }
    }
    @Test fun nativeQualitySwitchAndDoubleTapPreservePlaybackAndFullscreen() = fixture { _,model ->
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
        await("A double tap on the left did not resume playback") { model.player.playWhenReady && model.player.isPlaying }
        doubleTap(.8f)
        rule.runOnIdle { assertFalse(model.player.playWhenReady); assertTrue(model.player.currentPosition in 15000L..17000L) }
        doubleTap(.5f)
        await("The middle double tap did not resume playback") { model.player.playWhenReady && model.player.isPlaying }
        doubleTap(.5f)
        rule.runOnIdle {
            assertFalse(model.player.playWhenReady)
            assertSame(original,model.player); assertTrue(model.fullscreen)
            model.controlsVisible=true
        }
        rule.onNodeWithContentDescription("播放设置").performClick()
        rule.onNodeWithText("清晰度").assertIsDisplayed()
        rule.runOnIdle { assertFalse("Opening settings changed paused state",model.player.playWhenReady) }
        capture("02-playback-settings")
    }
    @Test fun pictureScrubPreviewsCommitsOnceAndCanBeCanceled() = fixture { _,model ->
        val surface=rule.onNodeWithContentDescription("视频画面")
        val original=model.player
        var seeks=0
        rule.runOnIdle { model.player.addListener(object: Player.Listener {
            override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo,newPosition: Player.PositionInfo,reason: Int) {
                if (reason==Player.DISCONTINUITY_REASON_SEEK) seeks++
            }
        }) }
        surface.performTouchInput { down(Offset(width*.3f,height*.5f)); moveTo(Offset(width*.55f,height*.5f),120) }
        rule.onAllNodesWithText("00:23 / 00:32").assertCountEquals(2)
        rule.runOnIdle { assertEquals(15000L,model.player.currentPosition); assertEquals(0,seeks) }
        surface.performTouchInput { up() }
        rule.runOnIdle {
            assertEquals(1,seeks); assertTrue(model.player.currentPosition in 22900L..23100L)
            assertSame(original,model.player); assertFalse(model.player.playWhenReady); assertEquals(1.5f,model.player.playbackParameters.speed)
        }
        surface.performTouchInput {
            down(Offset(width*.5f,height*.5f)); moveTo(Offset(width*.7f,height*.5f),100)
            moveTo(Offset(width*.92f,height*.08f),100)
        }
        rule.onNodeWithText("松手取消").assertIsDisplayed()
        surface.performTouchInput { up() }
        surface.performTouchInput {
            down(Offset(width*.6f,height*.5f)); moveTo(Offset(width*.4f,height*.5f),90); cancel()
        }
        rule.onNodeWithContentDescription("播放进度").performTouchInput {
            down(Offset(width*.4f,centerY)); moveTo(Offset(width*.7f,centerY),90); cancel()
        }
        rule.onNodeWithContentDescription("播放进度").performTouchInput {
            down(0,Offset(width*.3f,centerY)); down(1,Offset(width*.5f,centerY)); up(1)
            moveTo(0,Offset(width*.8f,centerY),90); up(0)
        }
        rule.runOnIdle { assertEquals(1,seeks); assertTrue(model.player.currentPosition in 22900L..23100L) }
    }
    @Test fun inlineSwipesAdjustOnlyTheSideTheyStartOn() = fixture { f,model ->
        val window=rule.activity.window
        val originalBrightness=window.attributes.screenBrightness
        val audio=rule.activity.getSystemService(AudioManager::class.java)
        val originalVolume=audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        val maximumVolume=audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val surface=rule.onNodeWithContentDescription("视频画面")
        fun swipe(x: Float,start: Float,end: Float, verify: () -> Unit) {
            surface.performTouchInput { down(Offset(width*x,height*start)); moveTo(Offset(width*x,height*end),120) }
            try { verify() } finally { surface.performTouchInput { up() } }
        }
        try {
            rule.runOnIdle { window.attributes=window.attributes.apply { screenBrightness=.5f } }
            for ((start,end) in listOf(.48f to .16f,.16f to .48f)) {
                swipe(.25f,start,end) {
                    val brightness=window.attributes.screenBrightness
                    assertTrue(if (start>end) brightness>.5f else brightness<.53f)
                    assertEquals(originalVolume,audio.getStreamVolume(AudioManager.STREAM_MUSIC))
                    rule.onNodeWithText("亮度 ${(brightness * 100).roundToInt()}%").assertIsDisplayed()
                }
            }
            if (!audio.isVolumeFixed) {
                val start=if (originalVolume>0) .16f else .48f
                val end=if (originalVolume>0) .48f else .16f
                val before=window.attributes.screenBrightness
                var volume=originalVolume
                for ((from,to) in listOf(start to end,end to start)) {
                    swipe(.75f,from,to) {
                        val actual=audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                        assertTrue(if (from>to) actual>volume else actual<volume)
                        assertEquals(before,window.attributes.screenBrightness)
                        rule.onNodeWithText("音量 ${(actual * 100f / maximumVolume).roundToInt()}%").assertIsDisplayed()
                        volume=actual
                    }
                }
            }
            rule.runOnIdle {
                assertFalse(model.fullscreen)
                assertFalse(model.player.playWhenReady)
                assertEquals(15000L,model.player.currentPosition)
                f.owner.back()
            }
            rule.waitUntil(3000) { window.attributes.screenBrightness==originalBrightness }
        } finally {
            rule.runOnUiThread { window.attributes=window.attributes.apply { screenBrightness=originalBrightness } }
            audio.setStreamVolume(AudioManager.STREAM_MUSIC,originalVolume,0)
        }
    }
    @Test fun fullscreenZonesAndLockPreservePlayerState() = fixture { _,model ->
        val original=model.player
        val window=rule.activity.window
        val initialBrightness=window.attributes.screenBrightness
        val audio=rule.activity.getSystemService(AudioManager::class.java)
        val oldVolume=audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        try {
            rule.runOnIdle { window.attributes=window.attributes.apply { screenBrightness=.5f } }
            rule.onNodeWithContentDescription("全屏").performClick()
            await("Portrait fullscreen did not open") { model.fullscreen && model.portraitFullscreen }
            val surface=rule.onNodeWithContentDescription("视频画面")
            surface.performTouchInput {
                down(Offset(width*.25f,height*.67f)); moveTo(Offset(width*.25f,height*.28f),120)
            }
            var brightnessPercent=0
            rule.runOnIdle {
                assertTrue(window.attributes.screenBrightness>.5f)
                assertEquals(oldVolume,audio.getStreamVolume(AudioManager.STREAM_MUSIC))
                brightnessPercent=(window.attributes.screenBrightness * 100).roundToInt()
            }
            rule.onNodeWithText("亮度 $brightnessPercent%").assertIsDisplayed()
            surface.performTouchInput { up() }
            surface.performTouchInput { swipe(Offset(width*.25f,height*.28f),Offset(width*.25f,height*.67f),320) }
            rule.runOnIdle { assertEquals(.5f,window.attributes.screenBrightness,.03f) }
            if (!audio.isVolumeFixed) {
                val start = if (oldVolume>0) .26f else .68f
                val end = if (oldVolume>0) .68f else .26f
                surface.performTouchInput {
                    down(Offset(width*.75f,height*start)); moveTo(Offset(width*.75f,height*end),120)
                }
                var adjustedVolume = oldVolume
                rule.runOnIdle {
                    adjustedVolume=audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                    assertTrue(if (oldVolume>0) adjustedVolume<oldVolume else adjustedVolume>oldVolume)
                    assertEquals(.5f,window.attributes.screenBrightness,.03f)
                }
                val volumePercent=(adjustedVolume * 100f / audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)).roundToInt()
                rule.onNodeWithText("音量 $volumePercent%").assertIsDisplayed()
                surface.performTouchInput { up() }
                surface.performTouchInput { swipe(Offset(width*.75f,height*end),Offset(width*.75f,height*start),320) }
                rule.runOnIdle {
                    val restored=audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                    assertTrue(if (oldVolume>0) restored>adjustedVolume else restored<adjustedVolume)
                }
            }
            rule.waitUntil(3000) {
                rule.onAllNodes(hasText("亮度 ", substring=true) or hasText("音量 ", substring=true)).fetchSemanticsNodes().isEmpty()
            }
            rule.runOnIdle { model.controlsVisible=true }
            rule.onNodeWithContentDescription("锁定播放器").performClick()
            surface.performTouchInput { swipe(Offset(width*.25f,height*.5f),Offset(width*.75f,height*.5f),320) }
            rule.runOnIdle { assertEquals(15000L,model.player.currentPosition); assertFalse(model.player.playWhenReady) }
            surface.performTouchInput { click(center) }
            rule.onNodeWithContentDescription("解锁播放器").performClick()
            surface.performTouchInput { swipe(Offset(width*.5f,height*.28f),Offset(width*.5f,height*.68f),500) }
            await("The portrait center drag did not exit fullscreen") { !model.fullscreen }
            rule.runOnIdle {
                assertSame(original,model.player); assertFalse(model.player.playWhenReady)
                assertEquals(.5f,window.attributes.screenBrightness)
            }
        } finally {
            rule.runOnUiThread { window.attributes=window.attributes.apply { screenBrightness=initialBrightness } }
            audio.setStreamVolume(AudioManager.STREAM_MUSIC,oldVolume,0)
        }
    }
    @Test fun fullscreenPinchAndTwoFingerTapStayIndependent() = fixture { _,model ->
        rule.onNodeWithContentDescription("全屏").performClick()
        val surface=rule.onNodeWithContentDescription("视频画面")
        fun findSurface(view: View): SurfaceView? = when(view) {
            is SurfaceView -> view
            is ViewGroup -> (0 until view.childCount).firstNotNullOfOrNull { findSurface(view.getChildAt(it)) }
            else -> null
        }
        capture("05-before-pinch")
        surface.performTouchInput {
            pinch(Offset(width*.42f,height*.5f),Offset(width*.58f,height*.5f),Offset(width*.32f,height*.5f),Offset(width*.68f,height*.5f),400)
        }
        rule.runOnIdle { assertFalse(model.danmaku); assertTrue(findSurface(rule.activity.window.decorView)!!.scaleX>1f) }
        capture("06-after-pinch")
        surface.performTouchInput {
            down(0,Offset(width*.44f,height*.5f)); down(1,Offset(width*.56f,height*.5f))
            advanceEventTime(90); up(1); up(0)
        }
        rule.runOnIdle { assertTrue(model.danmaku); assertFalse(model.player.playWhenReady); assertEquals(15000L,model.player.currentPosition); model.controlsVisible=true }
        rule.onAllNodesWithContentDescription("退出全屏").onLast().performClick()
        rule.runOnIdle { assertEquals(1f,findSurface(rule.activity.window.decorView)!!.scaleX) }
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
                "/x/v1/dm/list.so" -> "<i/>"
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

@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package app.bilight.android

import android.content.Intent
import android.content.res.Configuration
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import androidx.lifecycle.ViewModelProvider
import androidx.media3.ui.PlayerView
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.*
import app.bilight.android.playback.PlaybackModel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Explicit opt-in smoke test. Public anonymous reads only; never run against a logged-in account. */
class LivePlaybackLifecycleTest {
    // Match the explicit component launch used by deployment, then return with the real launcher Intent.
    @get:Rule val activity = ActivityScenarioRule<MainActivity>(Intent(ApplicationProvider.getApplicationContext(),MainActivity::class.java))
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun <T> main(block: () -> T): T {
        var result: Result<T>?=null
        instrumentation.runOnMainSync { result=runCatching(block) }
        return result!!.getOrThrow()
    }
    private fun waitFor(message: String, timeout: Long = 40000, condition: () -> Boolean) {
        val deadline=SystemClock.elapsedRealtime()+timeout
        while (SystemClock.elapsedRealtime()<deadline) { if (main(condition)) return; Thread.sleep(50) }
        throw AssertionError(message)
    }
    private fun surface(view: View): PlayerView? {
        if (view is PlayerView) return view
        if (view is ViewGroup) for (i in 0 until view.childCount) surface(view.getChildAt(i))?.let { return it }
        return null
    }
    @Test fun sensorsHomeReturnAndRenderedFramesKeepTheSameNativePlayer() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("livePlayback")=="true")
        lateinit var screen: MainActivity
        lateinit var app: AppModel
        activity.scenario.onActivity { screen=it; app=ViewModelProvider(it)[AppModel::class.java] }
        waitFor("Account restore did not finish") { !app.restoring }
        assumeTrue("This smoke test requires an anonymous emulator",main { app.user==null })
        val checkpoint=File(screen.filesDir,"live-playback-checkpoint.json")
        lateinit var model: PlaybackModel
        var measuring=false
        fun stage(value: String) {
            val data=main { JSONObject().put("stage",value).put("fullscreen",model.fullscreen).put("playing",model.player.isPlaying).put("position",model.player.currentPosition) }
            android.util.AtomicFile(checkpoint).let { file -> val stream=file.startWrite(); stream.write(data.toString().toByteArray()); file.finishWrite(stream) }
        }
        fun capture(value: String) {
            // Wait for the platform rotation animation before judging the settled layout.
            Thread.sleep(900); main { model.controlsVisible=true }; Thread.sleep(100)
            val bitmap=instrumentation.uiAutomation.takeScreenshot()
            val folder=File(screen.filesDir,"live-ui-audit").apply { mkdirs() }
            File(folder,"$value.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }; bitmap.recycle()
        }
        var malformedLandscapeFrames=0
        val preDraw=ViewTreeObserver.OnPreDrawListener {
            if (measuring && model.fullscreen && screen.resources.configuration.orientation==Configuration.ORIENTATION_LANDSCAPE) {
                surface(screen.window.decorView)?.let { if (it.height>0 && it.height < screen.window.decorView.height*.85f) malformedLandscapeFrames++ }
            }
            true
        }
        try {
            main { app.keyword="4K"; app.search() }
            waitFor("Public search did not complete") { !app.searchBusy }
            val sample=main { app.searchItems.filterIsInstance<Video>().firstOrNull { it.title.contains("影视飓风年度样片") } }
                ?: throw AssertionError("Public sample not present; do not replace an upstream failure with mock data")
            val route=Route.Watch(sample.bvid)
            main { app.open(route); model=app.playback(route); measuring=true; screen.window.decorView.viewTreeObserver.addOnPreDrawListener(preDraw) }
            waitFor("Public video did not start") { model.error?.let { throw AssertionError("Public playback failed: $it") }; model.hasFrame && model.player.isPlaying }
            val player=main { model.player }
            capture("01-public-inline")
            stage("await-landscape-left")
            waitFor("Sensor did not enter native landscape fullscreen") { model.fullscreen && screen.resources.configuration.orientation==Configuration.ORIENTATION_LANDSCAPE }
            capture("02-public-landscape-left")
            val firstRotation=main { screen.display!!.rotation }
            val beforeTurn=main { player.currentPosition }
            stage("await-landscape-right")
            waitFor("Opposite landscape rotation did not arrive") { screen.display!!.rotation!=firstRotation && screen.resources.configuration.orientation==Configuration.ORIENTATION_LANDSCAPE }
            waitFor("Playback stopped during rotation") { player.isPlaying && player.currentPosition>beforeTurn+250 }
            capture("03-public-landscape-right")
            instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_HOME").close()
            waitFor("Background playback was not paused") { !player.playWhenReady && screen.lifecycle.currentState==androidx.lifecycle.Lifecycle.State.CREATED }
            stage("home")
            val parked=main { player.currentPosition }
            Thread.sleep(10000)
            assertTrue("Playback advanced while hidden",main { player.currentPosition }-parked<500)
            val launch=screen.packageManager.getLaunchIntentForPackage(screen.packageName)!!
            screen.applicationContext.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED))
            waitFor("App did not resume playback after Home") { player.isPlaying }
            assertTrue("Fullscreen was lost on Home return",main { model.fullscreen })
            assertSame("Player was recreated on Home return",player,main { app.playback(route).player })
            val rendered=main { player.videoDecoderCounters?.renderedOutputBufferCount ?: 0 }
            waitFor("Video frames did not resume") { (player.videoDecoderCounters?.renderedOutputBufferCount ?: 0)>rendered }
            capture("04-public-return-fullscreen")
            stage("await-landscape-again")
            waitFor("Landscape after return failed") { model.fullscreen && screen.resources.configuration.orientation==Configuration.ORIENTATION_LANDSCAPE }
            stage("await-portrait")
            waitFor("Active portrait rotation did not restore the embedded player") { !model.fullscreen && screen.resources.configuration.orientation==Configuration.ORIENTATION_PORTRAIT }
            assertSame(player,main { app.playback(route).player })
            assertTrue(main { player.isPlaying })
            capture("05-public-portrait-inline")
            assertEquals("A landscape frame used the embedded layout",0,malformedLandscapeFrames)
            stage("passed")
        } finally {
            main { screen.window.decorView.viewTreeObserver.removeOnPreDrawListener(preDraw) }
            checkpoint.delete()
        }
    }
}

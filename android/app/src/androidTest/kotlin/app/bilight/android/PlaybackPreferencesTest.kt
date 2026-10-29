package app.bilight.android

import android.content.Context
import android.content.Intent
import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.graphics.Rect
import android.os.SystemClock
import android.view.MotionEvent
import android.view.ViewGroup
import androidx.activity.compose.setContent
import app.bilight.android.ui.MainApp
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.*
import app.bilight.android.core.Route
import app.bilight.android.playback.PlaybackModel
import app.bilight.android.playback.PlaybackSettings
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream

/** Exercise persisted device preferences through real PlaybackModel instances, with no platform calls. */
class PlaybackPreferencesTest {
    @get:Rule val activity=ActivityScenarioRule(MainActivity::class.java)
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private fun main(block: () -> Unit)=instrumentation.runOnMainSync(block)
    private fun await(message: String,condition: () -> Boolean) {
        var done=false; val deadline=android.os.SystemClock.elapsedRealtime()+7000
        while (!done && android.os.SystemClock.elapsedRealtime()<deadline) {
            main { done=condition() }; if (!done) Thread.sleep(20)
        }
        assertTrue(message,done)
    }
    private fun fixture(durationSeconds: Int = 1, audio: Boolean = false, authenticated: Boolean = false, test: (Fixture) -> Unit) {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish") && SessionVault(app).load()==null) { "Use only the isolated anonymous emulator" }
        val store=app.getSharedPreferences("playback-preferences",Context.MODE_PRIVATE)
        val saved=HashMap(store.all)
        store.edit().clear().commit()
        val fixture=Fixture(app,durationSeconds,audio,authenticated)
        try { test(fixture) } finally {
            fixture.close()
            store.edit().clear().apply {
                saved.forEach { (key,value) -> when (value) {
                    is Boolean -> putBoolean(key,value); is Int -> putInt(key,value); is Float -> putFloat(key,value)
                    is Long -> putLong(key,value); is String -> putString(key,value)
                } }
            }.commit()
        }
    }
    @Test fun lockScreenSessionPublishesMetadataAndControlsTheExistingPlayer() = fixture(30,audio=true) { f ->
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")); model.enableBackgroundPlayback() }
        await("Media did not start") { model.player.isPlaying }
        val notifications=f.app.getSystemService(NotificationManager::class.java)
        await("No system media notification was published") { notifications.activeNotifications.any { it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) } }
        val notification=notifications.activeNotifications.first { it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) }.notification
        assertEquals("The media card must be visible on the lock screen",Notification.VISIBILITY_PUBLIC,notification.visibility)
        val token=notification.extras.getParcelable(Notification.EXTRA_MEDIA_SESSION,MediaSession.Token::class.java)!!
        val controller=MediaController(f.app,token)
        assertEquals("A lock-screen card must identify the current video","偏好恢复测试",controller.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE))
        assertEquals("隔离测试",controller.metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST))
        check(!f.app.getSystemService(KeyguardManager::class.java).isDeviceSecure)
        main { model.background() }
        instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)
        instrumentation.uiAutomation.executeShellCommand("input keyevent 223").close()
        controller.transportControls.pause()
        await("System pause did not pause the actual player") { !model.player.playWhenReady }
        controller.transportControls.seekTo(2000)
        await("System seek did not update the actual player") { kotlin.math.abs(model.player.currentPosition-2000)<250 }
        main { assertFalse("Seeking a paused item must keep it paused",model.player.playWhenReady) }
        controller.transportControls.play()
        await("System play did not resume the same player") { model.player.isPlaying }
        instrumentation.uiAutomation.executeShellCommand("input keyevent 224").close()
        assertTrue(controller.playbackState!!.actions and PlaybackState.ACTION_SEEK_TO != 0L)
        main { model.close() }
        await("Closing playback must remove the media notification") { notifications.activeNotifications.none { it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) } }
    }
    @Test fun temporarySpeedAndBackgroundAudioPreserveTheSamePlayerAndUserPause() = fixture(8,audio=true) { f ->
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("The background audio fixture did not prepare") { model.playback!=null && !model.preparing }
        val player=model.player
        main {
            player.pause(); model.speed(1.5f); model.beginTemporarySpeed()
            assertFalse(player.playWhenReady); assertEquals(1.5f,player.playbackParameters.speed)
            model.enableBackgroundPlayback(); player.play()
        }
        await("The fixture must really be playing") { player.isPlaying }
        main { f.owner.open(model.route) }
        activity.scenario.onActivity { screen ->
            screen.findViewById<ViewGroup>(android.R.id.content).removeAllViews()
            screen.setContent { MainApp(f.owner) }
        }
        fun videoBounds(): Rect {
            fun find(node: android.view.accessibility.AccessibilityNodeInfo?): Rect? {
                if (node==null) return null
                if (node.contentDescription?.toString()=="视频画面") return Rect().also { node.getBoundsInScreen(it) }
                for (i in 0 until node.childCount) find(node.getChild(i))?.let { return it }
                return null
            }
            val deadline=SystemClock.elapsedRealtime()+3000
            while (SystemClock.elapsedRealtime()<deadline) {
                find(instrumentation.uiAutomation.rootInActiveWindow)?.let { if (!it.isEmpty) return it }
                Thread.sleep(30)
            }
            error("The actual video surface was not accessible")
        }
        for (fullscreen in listOf(false,true)) {
            main { model.fullscreen=fullscreen; model.portraitFullscreen=fullscreen; model.controlsVisible=false; model.seek(0); player.play() }
            instrumentation.waitForIdleSync()
            val bounds=videoBounds(); val down=SystemClock.uptimeMillis()
            fun touch(action: Int) {
                val event=MotionEvent.obtain(down,SystemClock.uptimeMillis(),action,bounds.exactCenterX(),bounds.exactCenterY(),0)
                try { check(instrumentation.uiAutomation.injectInputEvent(event,true)) } finally { event.recycle() }
            }
            touch(MotionEvent.ACTION_DOWN)
            try { Thread.sleep(650); main { assertEquals("The actual held surface did not accelerate (fullscreen=$fullscreen)",2f,player.playbackParameters.speed) } }
            finally { touch(MotionEvent.ACTION_UP) }
            Thread.sleep(80); main { assertEquals(1.5f,player.playbackParameters.speed) }
        }
        main {
            model.beginTemporarySpeed(); assertEquals(2f,player.playbackParameters.speed); assertEquals(1.5f,model.speed)
            model.endTemporarySpeed(); assertEquals(1.5f,player.playbackParameters.speed)
            model.seek(0); player.play()
            model.background()
        }
        val manager=f.app.getSystemService(ActivityManager::class.java)
        @Suppress("DEPRECATION")
        await("Media playback must be hosted by a foreground service") { manager.getRunningServices(100).any { it.service.className.endsWith(".PlaybackService") && it.foreground } }
        check(!f.app.getSystemService(KeyguardManager::class.java).isDeviceSecure)
        instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)
        var before=0L; main { before=player.currentPosition }
        try {
            instrumentation.uiAutomation.executeShellCommand("input keyevent 223").close()
            Thread.sleep(500)
            main { assertSame(player,model.player); assertTrue(player.playWhenReady); assertTrue("Audio stopped after Home and screen off",player.currentPosition>before+100); player.pause() }
        } finally {
            instrumentation.uiAutomation.executeShellCommand("input keyevent 224").close()
            instrumentation.uiAutomation.executeShellCommand("wm dismiss-keyguard").close()
            f.app.startActivity(Intent(f.app,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        main { model.foreground(); assertFalse("Foregrounding cannot undo a pause made while hidden",player.playWhenReady); assertSame(player,model.player) }
    }
    @Test fun optimisticLikeCoinAndTripleRollBackSilentlyWhileTotalsStayReal() = fixture(authenticated=true) { f ->
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("The initial account engagement did not load") { model.engagement!=null }
        val before=model.engagement!!
        for (action in listOf(VideoWrite.Like(true),VideoWrite.Coin(1,true),VideoWrite.Triple)) {
            f.engagementGate=CountDownLatch(1); f.failEngagement=true
            main {
                model.write(action)
                assertTrue("The pending icon did not update immediately",model.engagement!!.liked)
                if (action !is VideoWrite.Like) assertTrue(model.engagement!!.coins>0)
                if (action==VideoWrite.Triple) assertTrue(model.engagement!!.favorite)
                assertEquals(0L,model.detail!!.statistics.likes)
            }
            f.engagementGate!!.countDown()
            await("The failed operation did not finish") { !model.actionBusy }
            main { assertEquals(before,model.engagement); assertNull(model.supportError) }
        }
    }
    @Test fun explicitQualitySurvivesNewPlayersAndUnavailableQualityDoesNotReplaceIt() = fixture { f ->
        val preferences=PlaybackSettings(f.app)
        fun open(bvid: String): PlaybackModel {
            lateinit var model: PlaybackModel
            main { model=f.owner.playback(Route.Watch(bvid)) }
            await("The fixture video did not finish preparing") { model.playback!=null && !model.preparing }
            main { assertNull(model.error); model.player.pause() }
            return model
        }
        val high="BV12qnt6VEM1"; val low="BV1NGZtBwELa"
        val first=open(high)
        main {
            assertEquals(120,first.playback!!.quality)
            assertEquals("An automatic selection overwrote the preference",127,preferences.quality)
            first.chooseQuality(120); assertEquals(120,preferences.quality)
        }
        val lower=open(low)
        main {
            assertEquals(80,lower.playback!!.quality)
            assertEquals("Fallback replaced the preferred higher quality",120,preferences.quality)
            lower.chooseQuality(120); assertEquals(120,preferences.quality)
        }
        val restored=open(high)
        main { assertEquals("The original quality was not restored",120,restored.playback!!.quality) }
        val selectedLower=open(low)
        main { selectedLower.chooseQuality(80); assertEquals(80,PlaybackSettings(f.app).quality) }
        val last=open(high)
        main { assertEquals(80,last.playback!!.quality) }
        assertEquals(listOf(127,120,120,120,80),f.requestedQualities.toList())
    }
    @Test fun danmakuPreferencesPersistAndStyleChangesOrCancelledReadsCannotRefetchOrResurrectIt() = fixture { f ->
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("Initial subtitles were not selected") { model.cues.isNotEmpty() }
        main { assertFalse(model.danmaku); assertEquals("zh-CN",model.subtitle!!.language) }
        assertEquals(0,f.danmakuReads.get())
        main { model.danmaku(true) }
        await("Compressed comments were not loaded") { model.danmakuItems.isNotEmpty() }
        assertEquals(1,f.danmakuReads.get())
        main {
            model.font(24); model.area(.5f); model.opacity(.75f)
            model.subtitle(null); assertTrue(model.cues.isEmpty()); assertEquals("",model.subtitleText)
        }
        Thread.sleep(150)
        assertEquals("A style change refetched comments",1,f.danmakuReads.get())
        val samePlayer=model.player
        main { model.selectPart(model.detail!!.parts[1]) }
        await("The second part did not replace the old comments") { model.danmakuItems.singleOrNull()?.text=="cid-44" }
        main {
            assertSame(samePlayer,model.player); assertTrue(model.danmaku)
            assertTrue("A manually selected part did not request playback",model.player.playWhenReady)
        }
        assertEquals(2,f.danmakuReads.get())
        main { model.danmaku(false) }
        f.danmakuGate=CountDownLatch(1)
        main { model.danmaku(true) }
        await("The delayed comment request did not begin") { f.danmakuReads.get()==3 }
        main { model.danmaku(false) }
        f.danmakuGate!!.countDown(); Thread.sleep(150)
        main { assertTrue(model.danmakuItems.isEmpty()); assertNull(model.danmakuError); f.owner.releasePlayback(model) }
        f.danmakuGate=null
        main { model=f.owner.playback(Route.Watch("BV1NGZtBwELa")) }
        await("The reopened video did not prepare") { model.playback!=null && !model.preparing }
        main {
            assertFalse(model.danmaku); assertEquals(24,model.danmakuFont)
            assertEquals(.5f,model.danmakuArea); assertEquals(.75f,model.danmakuOpacity)
        }
        assertEquals("Disabled comments were fetched in the next video",3,f.danmakuReads.get())
        main { model.danmaku(true) }
        await("Comments did not reenable") { model.danmakuItems.isNotEmpty() }
        main { f.owner.releasePlayback(model); model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("Enabled comments were not restored in a new player") { model.danmakuItems.isNotEmpty() }
        main { assertTrue(model.danmaku); assertTrue(PlaybackSettings(f.app).danmaku) }
        assertEquals(5,f.danmakuReads.get())
    }
    private inner class Fixture(val app: BilightApplication, durationSeconds: Int, audio: Boolean, authenticated: Boolean) {
        val requestedQualities=CopyOnWriteArrayList<Int>()
        val danmakuReads=AtomicInteger()
        @Volatile var danmakuGate: CountDownLatch?=null
        @Volatile var engagementGate: CountDownLatch?=null
        @Volatile var failEngagement=false
        private val file=File(app.cacheDir,"preferences-fixture.mp4").also { encodedFixture(it,audio,durationSeconds) }
        private val bytes=file.readBytes()
        private val api=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); val path=request.url.encodedPath
            val text=when (path) {
                "/x/web-interface/nav" -> """{"code":0,"data":{"isLogin":$authenticated,"mid":900000003,"uname":"隔离测试","wbi_img":{"img_url":"https://i0.hdslb.com/${"a".repeat(32)}.png","sub_url":"https://i0.hdslb.com/${"b".repeat(32)}.png"}}}"""
                "/x/web-interface/archive/relation" -> { check(engagementGate?.await(5,TimeUnit.SECONDS)!=false); if (failEngagement) throw java.io.IOException("Isolated engagement failure"); """{"code":0,"data":{"like":false,"coin":0,"favorite":false}}""" }
                "/x/web-interface/wbi/view" -> """{"code":0,"data":{"bvid":"${request.url.queryParameter("bvid")}","aid":42,"title":"偏好恢复测试","duration":1,"owner":{"mid":42,"name":"隔离测试"},"pages":[{"cid":43,"page":1,"part":"第一段","duration":1},{"cid":44,"page":2,"part":"第二段","duration":1}],"stat":{}}}"""
                "/x/player/wbi/playurl" -> {
                    val preferred=request.url.queryParameter("qn")!!.toInt(); requestedQualities+=preferred
                    val quality=minOf(preferred,if(request.url.queryParameter("bvid")=="BV12qnt6VEM1") 120 else 80)
                    """{"code":0,"data":{"quality":$quality,"timelength":1000,"durl":[{"url":"https://audit.bilivideo.com/preferences.mp4"}]}}"""
                }
                "/x/player/wbi/v2" -> """{"code":0,"data":{"subtitle":{"subtitles":[{"id":1,"lan":"en","lan_doc":"English","subtitle_url":"https://i0.hdslb.com/en.json"},{"id":2,"lan":"zh-CN","lan_doc":"中文","subtitle_url":"https://i0.hdslb.com/zh.json"}]}}}"""
                "/en.json", "/zh.json" -> """{"body":[{"from":0,"to":1,"content":"字幕测试"}]}"""
                "/x/v2/reply/wbi/main" -> """{"code":0,"data":{"cursor":{"is_end":true,"all_count":0},"replies":[]}}"""
                "/x/v1/dm/list.so" -> {
                    danmakuReads.incrementAndGet(); check(danmakuGate?.await(5,TimeUnit.SECONDS)!=false)
                    """<i><d p="0,1,25,16777215">cid-${request.url.queryParameter("oid")}</d></i>"""
                }
                else -> error("Unexpected fixture request: $path")
            }
            val body=if(path=="/x/v1/dm/list.so") ByteArrayOutputStream().also { output ->
                val deflater=Deflater(6,true)
                try { DeflaterOutputStream(output,deflater).use { it.write(text.toByteArray()) } } finally { deflater.end() }
            }.toByteArray() else text.toByteArray()
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body.toResponseBody("application/octet-stream".toMediaType())).build()
        }.build()
        private val media=OkHttpClient.Builder().addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(bytes.toResponseBody("video/mp4".toMediaType())).build()
        }.build()
        private val store=ViewModelStore()
        val owner: AppModel
        init {
            val http=BiliHttp(object: SecureStore { var saved: ByteArray?=null; override fun load()=saved; override fun save(bytes: ByteArray) { saved=bytes }; override fun clear() { saved=null } },api)
            if (authenticated) kotlinx.coroutines.runBlocking { http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only") }
            lateinit var value: AppModel
            main { value=ViewModelProvider(store,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) { a,r -> PlaybackModel(a,r,media) } as T
            })[AppModel::class.java] }
            owner=value
            await("The isolated session did not restore") { !owner.restoring }
        }
        fun close() {
            danmakuGate?.countDown(); engagementGate?.countDown(); main { store.clear() }; api.dispatcher.cancelAll(); media.dispatcher.cancelAll(); file.delete()
        }
    }
}

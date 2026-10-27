package app.bilight.android

import android.content.Context
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
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private fun main(block: () -> Unit)=instrumentation.runOnMainSync(block)
    private fun await(message: String,condition: () -> Boolean) {
        var done=false; val deadline=android.os.SystemClock.elapsedRealtime()+7000
        while (!done && android.os.SystemClock.elapsedRealtime()<deadline) {
            main { done=condition() }; if (!done) Thread.sleep(20)
        }
        assertTrue(message,done)
    }
    private fun fixture(test: (Fixture) -> Unit) {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish") && SessionVault(app).load()==null) { "Use only the isolated anonymous emulator" }
        val store=app.getSharedPreferences("playback-preferences",Context.MODE_PRIVATE)
        val saved=HashMap(store.all)
        store.edit().clear().commit()
        val fixture=Fixture(app)
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
    private inner class Fixture(val app: BilightApplication) {
        val requestedQualities=CopyOnWriteArrayList<Int>()
        val danmakuReads=AtomicInteger()
        @Volatile var danmakuGate: CountDownLatch?=null
        private val file=File(app.cacheDir,"preferences-fixture.mp4").also { encodedFixture(it,false) }
        private val bytes=file.readBytes()
        private val api=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); val path=request.url.encodedPath
            val text=when (path) {
                "/x/web-interface/nav" -> """{"code":0,"data":{"isLogin":false,"wbi_img":{"img_url":"https://i0.hdslb.com/${"a".repeat(32)}.png","sub_url":"https://i0.hdslb.com/${"b".repeat(32)}.png"}}}"""
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
            val http=BiliHttp(object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} },api)
            lateinit var value: AppModel
            main { value=ViewModelProvider(store,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) { a,r -> PlaybackModel(a,r,media) } as T
            })[AppModel::class.java] }
            owner=value
            await("The isolated session did not restore") { !owner.restoring }
        }
        fun close() {
            danmakuGate?.countDown(); main { store.clear() }; api.dispatcher.cancelAll(); media.dispatcher.cancelAll(); file.delete()
        }
    }
}

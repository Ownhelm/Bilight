package app.bilight.android

import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.media3.common.Player
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.*
import app.bilight.android.core.Route
import app.bilight.android.playback.PlaybackModel
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class PlaybackEndStateTest {
    @Test fun aShortVideoEndingBeforeItsSurfaceAppearsDoesNotKeepTheLoadingOverlay() {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        val file=File(app.cacheDir,"end-state-fixture.mp4"); encodedFixture(file,false)
        val bytes=file.readBytes()
        val api=OkHttpClient.Builder().addInterceptor { chain ->
            val body=when(chain.request().url.encodedPath) {
                "/x/web-interface/nav" -> """{"code":0,"data":{"isLogin":false,"wbi_img":{"img_url":"https://i0.hdslb.com/${"a".repeat(32)}.png","sub_url":"https://i0.hdslb.com/${"b".repeat(32)}.png"}}}"""
                "/x/web-interface/wbi/view" -> """{"code":0,"data":{"bvid":"BV12qnt6VEM1","aid":42,"title":"短视频结束状态测试","duration":1,"owner":{"mid":42,"name":"隔离测试"},"pages":[{"cid":43,"page":1,"part":"正片","duration":1}],"stat":{}}}"""
                "/x/player/wbi/playurl" -> """{"code":0,"data":{"quality":80,"timelength":1000,"durl":[{"url":"https://audit.bilivideo.com/clip.mp4"}]}}"""
                "/x/player/wbi/v2" -> """{"code":0,"data":{"subtitle":{"subtitles":[]}}}"""
                "/x/v2/reply/wbi/main" -> """{"code":0,"data":{"cursor":{"is_end":true,"all_count":0},"replies":[]}}"""
                "/x/v1/dm/list.so" -> "<i/>"
                else -> """{"code":-404}"""
            }
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body.toResponseBody("application/json".toMediaType())).build()
        }.build()
        val media=OkHttpClient.Builder().addInterceptor { chain -> Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(bytes.toResponseBody("video/mp4".toMediaType())).build() }.build()
        val http=BiliHttp(object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} },api)
        val instrumentation=InstrumentationRegistry.getInstrumentation(); val store=ViewModelStore()
        lateinit var owner: AppModel; lateinit var model: PlaybackModel
        try {
            instrumentation.runOnMainSync {
                owner=ViewModelProvider(store,object: ViewModelProvider.Factory {
                    @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) { a,r -> PlaybackModel(a,r,media) } as T
                })[AppModel::class.java]
                model=owner.playback(Route.Watch("BV12qnt6VEM1"))
            }
            var ended=false; val deadline=android.os.SystemClock.elapsedRealtime()+10000
            while (!ended && android.os.SystemClock.elapsedRealtime()<deadline) {
                instrumentation.runOnMainSync { ended=model.player.playbackState==Player.STATE_ENDED }; if (!ended) Thread.sleep(25)
            }
            assertTrue("The short native video did not reach its real end",ended)
            instrumentation.runOnMainSync {
                assertFalse(model.hasFrame)
                assertFalse("The finished video incorrectly kept showing loading",model.buffering)
                model.toggle()
                assertTrue("Replaying an ended video required a second tap",model.player.playWhenReady)
                assertEquals(0L,model.player.currentPosition)
            }
        } finally { instrumentation.runOnMainSync { owner.releasePlayback(model); store.clear() }; file.delete() }
    }
}

package app.bilight.android

import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.*
import app.bilight.android.playback.Danmaku
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/** Explicit anonymous emulator read; no login, user cookies, interactions or comment text in logs. */
class LiveDanmakuTest {
    @Test fun recordedPublicResponseReplaysThroughTheAndroidParser() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("recordedDanmaku")=="true")
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish"))
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(SessionVault(app).load()==null)
        val folder=File(app.filesDir,"danmaku-acceptance")
        val values=Danmaku.parse(File(folder,"public-response.bin").readBytes())
        assertTrue("The recorded real response must contain comments",values.isNotEmpty())
        File(folder,"replay-result.json").writeText(JSONObject().put("passed",true).put("comments",values.size).toString(2))
    }
    @Test fun realPublicResponseProducesReadableComments() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("liveDanmaku")=="true")
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish"))
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        check(SessionVault(app).load()==null)
        val vault=object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} }
        val http=BiliHttp(vault); val repository=BiliRepository(http)
        try {
            val sample=repository.search("4K",false,1).items.filterIsInstance<Video>().first { it.title.contains("影视飓风年度样片") }
            val detail=repository.detail(sample.bvid); val cid=detail.parts.first().cid
            val bytes=http.bytes("https://api.bilibili.com/x/v1/dm/list.so?oid=$cid")
            val folder=File(app.filesDir,"danmaku-acceptance").apply { mkdirs() }
            File(folder,"public-response.bin").writeBytes(bytes)
            val metadata=JSONObject().put("bvid",sample.bvid).put("cid",cid).put("bytes",bytes.size).put("prefix_hex",bytes.take(8).joinToString("") { "%02x".format(it.toInt() and 255) })
            File(folder,"result.json").writeText(metadata.toString(2))
            val values=Danmaku.parse(bytes)
            assertTrue("The selected public sample did not return any real comments",values.isNotEmpty())
            assertTrue(values.all { it.text.isNotBlank() && it.time.isFinite() })
            metadata.put("passed",true).put("comments",values.size); File(folder,"result.json").writeText(metadata.toString(2))
        } finally { http.client.dispatcher.cancelAll(); http.client.connectionPool.evictAll(); http.client.dispatcher.executorService.shutdown() }
    }
}

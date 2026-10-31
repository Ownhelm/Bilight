package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PlaybackSourceTest {
    private fun track(id: Int = 80, codec: String = "avc1.640028") = JSONObject()
        .put("id",id).put("codecs",codec).put("bandwidth",1000000)
        .put("baseUrl","https://primary.bilivideo.com:4483/video.m4s")
        .put("backup_url",JSONArray(listOf("https://untrusted.example/video.m4s","https://backup.bilivideo.com/video.m4s")))
        .put("SegmentBase",JSONObject().put("Initialization","0-999").put("indexRange","1000-1999"))
    private fun dash(vararg tracks: JSONObject) = JSONObject().put("dash",JSONObject()
        .put("duration",60).put("video",JSONArray(tracks.toList())).put("audio",JSONArray()))
    private fun mp4() = JSONObject().put("format","mp4").put("quality",64).put("timelength",60000)
        .put("durl",JSONArray().put(JSONObject().put("url","https://cdn.bilivideo.com/video.mp4")))
    private fun repository(handler: (Request) -> JSONObject): BiliRepository {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val data = if (request.url.encodedPath.endsWith("/nav")) JSONObject().put("wbi_img",JSONObject()
                .put("img_url","https://i0.hdslb.com/"+"a".repeat(32)+".png")
                .put("sub_url","https://i0.hdslb.com/"+"b".repeat(32)+".png")) else handler(request)
            val raw = if (data.has("code")) data else JSONObject().put("code",0).put("data",data)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(raw.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        return BiliRepository(BiliHttp(object: SecureStore {
            override fun load(): ByteArray? = null
            override fun save(bytes: ByteArray) {}
            override fun clear() {}
        },client))
    }
    @Test fun rejectedPrimaryUsesSafeBackupAtTheSameQualityWithoutAnotherRequest() = runBlocking {
        var reads = 0
        val repository = repository { request ->
            reads++; assertEquals("4048",request.url.queryParameter("fnval"))
            dash(track(120),track(80))
        }
        val source = repository.playback("BV0000000001",42,127)
        assertEquals(120,source.quality)
        assertEquals(listOf(120,80),source.qualities.map { it.id })
        assertEquals("https://backup.bilivideo.com/video.m4s",source.video!!.url)
        assertNull(source.mp4); assertEquals(1,reads)
    }
    @Test fun bothBackupFieldNamesAreCheckedWithoutAcceptingForeignHosts() {
        val raw = track().put("backupUrl",JSONArray(listOf("https://evilbilivideo.com/video.m4s")))
        assertEquals("https://backup.bilivideo.com/video.m4s",Track.parse(raw)!!.url)
        raw.put("backup_url",JSONArray(listOf("https://user:secret@a.bilivideo.com/file","https://a.bilivideo.com:4483/file")))
        assertNull(Track.parse(raw))
    }
    @Test fun missingAVCReadsOfficialMP4OnceWithTheSameVideoPartAndPreference() = runBlocking {
        val formats = mutableListOf<String>()
        val repository = repository { request ->
            assertEquals("BV0000000001",request.url.queryParameter("bvid"))
            assertEquals("42",request.url.queryParameter("cid")); assertEquals("120",request.url.queryParameter("qn"))
            assertEquals("https://www.bilibili.com/video/BV0000000001",request.header("Referer"))
            val format = request.url.queryParameter("fnval")!!; formats.add(format)
            if (format == "4048") dash(track(codec="hev1.1.6.L120.90")) else mp4()
        }
        val source = repository.playback("BV0000000001",42,120)
        assertEquals(listOf("4048","1"),formats); assertEquals(64,source.quality)
        assertEquals(listOf(64),source.qualities.map { it.id }); assertNotNull(source.mp4)
    }
    @Test fun unusableAudioFallsBackInsteadOfSilentlyPlayingWithoutSound() = runBlocking {
        val repository = repository { request ->
            if (request.url.queryParameter("fnval") == "1") mp4()
            else dash(track()).apply { obj("dash").put("audio",JSONArray().put(track(30251,"fLaC"))) }
        }
        assertNotNull(repository.playback("BV0000000001",42,80).mp4)
    }
    @Test fun completeMP4CanUseASafeBackupButFLVAndMultipleSegmentsCannotPass() {
        val data = mp4()
        data.rows("durl").single().put("url","https://cdn.bilivideo.com:4483/video.mp4")
            .put("backupUrl",JSONArray(listOf("https://backup.bilivideo.com/video.mp4")))
        assertEquals("https://backup.bilivideo.com/video.mp4",BiliRepository.mapPlayback(data,80).mp4)
        val flv = mp4().put("format","flv")
        flv.rows("durl").single().put("url","https://cdn.bilivideo.com/video.flv")
        assertThrows(BiliFailure::class.java) { BiliRepository.mapPlayback(flv,80) }
        data.getJSONArray("durl").put(JSONObject().put("url","https://cdn.bilivideo.com/part2.mp4"))
        assertThrows(BiliFailure::class.java) { BiliRepository.mapPlayback(data,80) }
    }
    @Test fun permissionErrorsAreNotReplacedWithANoAVCError() = runBlocking {
        for (stage in listOf("4048","1")) {
            val reads = mutableListOf<String>()
            val repository = repository { request ->
                val format = request.url.queryParameter("fnval")!!; reads.add(format)
                if (format == stage) JSONObject().put("code",-10403).put("message","真实权限错误")
                else dash(track(codec="hev1.1.6.L120.90"))
            }
            try { repository.playback("BV0000000001",42,80); fail("Expected upstream failure") }
            catch (e: BiliFailure) { assertEquals("-10403",e.code); assertTrue(e.message!!.contains("真实权限错误")) }
            assertEquals(if (stage == "4048") listOf("4048") else listOf("4048","1"),reads)
        }
    }
    @Test fun networkFailureDuringFallbackKeepsTheNetworkError() = runBlocking {
        var reads = 0
        val repository = repository { request ->
            reads++
            if (request.url.queryParameter("fnval") == "1") throw java.net.UnknownHostException("isolated fixture")
            dash(track(codec="hev1.1.6.L120.90"))
        }
        try { repository.playback("BV0000000001",42,80); fail("Expected network failure") }
        catch (e: BiliFailure) { assertEquals("NETWORK",e.code) }
        assertEquals(2,reads)
    }
    @Test fun unavailableMP4StopsAfterOneFallbackAndDoesNotBlameTheAccount() = runBlocking {
        var reads = 0
        val repository = repository { reads++; dash(track(codec="hev1.1.6.L120.90")) }
        try { repository.playback("BV0000000001",42,80); fail("Expected missing source") }
        catch (e: BiliFailure) { assertEquals("PLAYBACK_UNAVAILABLE",e.code); assertFalse(e.message!!.contains("账号")) }
        assertEquals(2,reads)
    }
    @Test fun accountChangesCannotStartAFallbackOrReturnTheOldSource() = runBlocking {
        for (playable in listOf(false,true)) {
            val entered = CompletableDeferred<Unit>(); val release = java.util.concurrent.CountDownLatch(1)
            var reads = 0
            val repository = repository {
                reads++; entered.complete(Unit); check(release.await(5,java.util.concurrent.TimeUnit.SECONDS))
                if (playable) dash(track()) else dash(track(codec="hev1.1.6.L120.90"))
            }
            val result = async { runCatching { repository.playback("BV0000000001",42,80) } }
            entered.await(); repository.http.logout(); release.countDown()
            assertEquals("ACCOUNT_CHANGED",(result.await().exceptionOrNull() as BiliFailure).code)
            assertEquals(1,reads)
        }
    }
}

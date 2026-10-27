package app.bilight.android

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import app.bilight.android.core.*
import app.bilight.android.downloads.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class DownloadStoreTest {
    @Test fun completeDownloadIsEncryptedRestoredAndHiddenFromOtherAccounts() = runBlocking {
        val application=ApplicationProvider.getApplicationContext<Context>()
        val directory=File(application.cacheDir,"download-store-test-${UUID.randomUUID()}").apply { mkdirs() }
        val context=object: ContextWrapper(application) {
            override fun getFilesDir()=File(directory,"files").apply { mkdirs() }
            override fun getNoBackupFilesDir()=File(directory,"private").apply { mkdirs() }
        }
        val uid=90000000000001L
        val certificate=HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val tls=HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val server=MockWebServer(); server.useHttps(tls.sslSocketFactory(),false)
        var store: DownloadStore?=null
        try {
            val video=File(directory,"fixture-video.mp4"); val audio=File(directory,"fixture-audio.mp4")
            withContext(Dispatchers.IO) { encodedFixture(video,false); encodedFixture(audio,true) }
            val videoBytes=video.readBytes(); val audioBytes=audio.readBytes()
            val owner=JSONObject().put("mid",1).put("name","隔离作者")
            val source=JSONObject().put("bvid","BV1NGZtBwELa").put("aid",42).put("title","离线测试视频").put("duration",1).put("owner",owner)
                .put("copyright",1).put("pages",JSONArray().put(JSONObject().put("cid",84).put("page",1).put("part","P1").put("duration",1)))
            fun track(audio: Boolean)=JSONObject().put("id",if (audio) 30280 else 80).put("baseUrl","https://fixture.bilivideo.com/${if (audio) "audio" else "video"}")
                .put("codecs",if (audio) "mp4a.40.2" else "avc1.640028").put("bandwidth",128000).put("width",64).put("height",64)
                .put("SegmentBase",JSONObject().put("Initialization","0-99").put("indexRange","100-199"))
            server.dispatcher=object: Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val data=when (request.requestUrl!!.encodedPath) {
                        "/x/web-interface/nav" -> JSONObject().put("isLogin",true).put("mid",uid).put("uname","隔离测试")
                            .put("wbi_img",JSONObject().put("img_url","https://fixture.hdslb.com/"+"a".repeat(32)+".png").put("sub_url","https://fixture.hdslb.com/"+"b".repeat(32)+".png"))
                        "/x/web-interface/wbi/view" -> source
                        "/x/player/wbi/playurl" -> JSONObject().put("dash",JSONObject().put("duration",1).put("video",JSONArray().put(track(false))).put("audio",JSONArray().put(track(true))))
                            .put("accept_quality",JSONArray().put(80)).put("accept_description",JSONArray().put("1080P"))
                        "/video","/audio" -> return MockResponse().setHeader("Content-Type","video/mp4").setHeader("ETag","\"fixture\"")
                            .setBody(okio.Buffer().write(if (request.requestUrl!!.encodedPath=="/video") videoBytes else audioBytes))
                        else -> return MockResponse().setResponseCode(404)
                    }
                    return MockResponse().setBody(JSONObject().put("code",0).put("data",data).toString())
                }
            }
            server.start()
            val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).addInterceptor { chain ->
                val original=chain.request(); val url=server.url(original.url.encodedPath).newBuilder().encodedQuery(original.url.encodedQuery).build()
                chain.proceed(original.newBuilder().url(url).build()).newBuilder().request(original).build()
            }.build()
            val memory=object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} }
            val http=BiliHttp(memory,client); http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only")
            val repository=BiliRepository(http); val detail=repository.detail("BV1NGZtBwELa")
            val queue=DownloadStore(context,repository,client,{})
            store=queue; withContext(Dispatchers.Main) { queue.account(uid) }
            withTimeout(10000) { while (!withContext(Dispatchers.Main) { queue.ready }) delay(20) }
            val complete=CompletableDeferred<Unit>()
            withContext(Dispatchers.Main) { queue.enqueue(detail,detail.parts.single(),Quality(80,"1080P")); queue.processQueue { complete.complete(Unit) } }
            withTimeout(15000) { complete.await() }
            val item=withContext(Dispatchers.Main) { queue.items.single() }
            assertEquals(item.error,DownloadState.COMPLETED,item.state)
            assertTrue(withContext(Dispatchers.Main) { queue.file(item) }!!.length()>0)
            withContext(Dispatchers.Main) { queue.account(null); assertTrue(queue.items.isEmpty()); assertNull(queue.file(item)); queue.awaitSaved() }
            val encrypted=File(context.noBackupFilesDir,"downloads-$uid.enc").readBytes()
            assertFalse(String(encrypted).contains("离线测试视频")); assertFalse(String(encrypted).contains("BV1NGZtBwELa"))
            withContext(Dispatchers.Main) { queue.account(uid) }
            withTimeout(10000) { while (!withContext(Dispatchers.Main) { queue.ready }) delay(20) }
            assertEquals(item,withContext(Dispatchers.Main) { queue.items.single() })
        } finally {
            withContext(Dispatchers.Main) { store?.account(null); store?.awaitSaved() }
            SessionVault(context,"downloads-$uid").clear(); server.shutdown(); directory.deleteRecursively()
        }
    }
}

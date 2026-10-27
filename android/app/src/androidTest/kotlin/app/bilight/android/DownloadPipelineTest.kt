package app.bilight.android

import androidx.test.core.app.ApplicationProvider
import app.bilight.android.core.BiliFailure
import app.bilight.android.downloads.downloadTrack
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

class DownloadPipelineTest {
    private fun <T> fixture(body: (MockWebServer, OkHttpClient, File) -> T): T {
        val server = MockWebServer()
        val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        server.useHttps(serverTls.sslSocketFactory(), false); server.start()
        val directory = File(ApplicationProvider.getApplicationContext<android.content.Context>().cacheDir,"download-test-${UUID.randomUUID()}").apply { mkdirs() }
        val client = OkHttpClient.Builder().sslSocketFactory(clientTls.sslSocketFactory(),clientTls.trustManager)
            .readTimeout(3,TimeUnit.SECONDS).addInterceptor { chain ->
                // Local TLS fixture only; this interceptor is never part of the installed app's client.
                val local = server.url(chain.request().url.encodedPath)
                chain.proceed(chain.request().newBuilder().url(local).build())
            }.build()
        try { return body(server,client,directory) }
        finally { client.dispatcher.cancelAll(); server.shutdown(); directory.deleteRecursively() }
    }
    @Test fun realStreamResumesWithExactRangeAndStrongValidator() = fixture { server, client, directory -> runBlocking(Dispatchers.IO) {
        val file = File(directory,"video.track").apply { writeText("abcd") }
        File(directory,"video.track.range").writeText("\"stable\"\n10")
        server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Type","video/mp4").setHeader("ETag","\"stable\"").setHeader("Content-Range","bytes 4-9/10").setBody("efghij"))
        downloadTrack(client,"https://fixture.bilivideo.com/video",file) { _,_ -> }
        assertEquals("abcdefghij",file.readText())
        val request = server.takeRequest(); assertEquals("bytes=4-",request.getHeader("Range")); assertEquals("\"stable\"",request.getHeader("If-Range")); assertNull(request.getHeader("Cookie"))
    } }
    @Test fun renewedUrlCannotAppendAnotherFilesBytes() = fixture { server, client, directory -> runBlocking(Dispatchers.IO) {
        val file = File(directory,"video.track").apply { writeText("abcd") }
        File(directory,"video.track.range").writeText("\"old\"\n10")
        server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Type","video/mp4").setHeader("ETag","\"new\"").setHeader("Content-Range","bytes 4-9/10").setBody("xxxxxx"))
        try { downloadTrack(client,"https://fixture.bilivideo.com/video",file) { _,_ -> }; fail() }
        catch (e: BiliFailure) { assertEquals("RESUME_CHANGED",e.code) }
        assertEquals("abcd",file.readText())
    } }
    @Test fun cancellingTheTransferInterruptsBodyReadAndRetainsOnlyItsOwnPrefix() = fixture { server, client, directory -> runBlocking {
        val file = File(directory,"video.track")
        server.enqueue(MockResponse().setHeader("Content-Type","video/mp4").setHeader("ETag","\"stable\"").setBody("x".repeat(65536)).throttleBody(1024,100,TimeUnit.MILLISECONDS))
        val started = CompletableDeferred<Unit>()
        val job = launch(Dispatchers.IO) { downloadTrack(client,"https://fixture.bilivideo.com/video",file) { _,_ -> started.complete(Unit) } }
        withTimeout(5000) { started.await() }; job.cancelAndJoin()
        assertTrue(file.length() in 1L..65535L)
        assertEquals("x".repeat(file.length().toInt()),file.readText())
    } }
}

package app.bilight.android

import app.bilight.android.core.BiliFailure
import app.bilight.android.downloads.downloadTrack
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okio.Buffer
import okio.BufferedSource
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files

/** Exercise the real stream-to-disk path without binding a server or using an account. */
class DownloadTransferTest {
    private fun response(request: Request, bytes: String, code: Int = 206, range: String = "bytes 0-9/10", etag: String? = null): Response {
        val body = object: ResponseBody() {
            private val buffer = Buffer().writeUtf8(bytes)
            override fun contentType(): MediaType? = null
            override fun contentLength() = -1L
            override fun source(): BufferedSource = buffer
        }
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(code).message("Fixture")
            .header("Content-Type",if (code == 403) "text/html" else "video/mp4")
            .header("Content-Range",range).apply { etag?.let { header("ETag",it) } }.body(body).build()
    }
    private fun fixture(block: suspend (File) -> Unit) = runBlocking(Dispatchers.IO) {
        val directory = Files.createTempDirectory("bilight-download-test").toFile()
        try { block(directory) } finally { directory.deleteRecursively() }
    }
    @Test fun fullChunkedDownloadSendsRangeAndStoresExactlyTheProvenFile() = fixture { directory ->
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            assertEquals("bytes=0-",chain.request().header("Range"))
            assertEquals("identity",chain.request().header("Accept-Encoding"))
            assertNull(chain.request().header("Cookie"))
            response(chain.request(),"abcdefghij")
        }.build()
        val file = File(directory,"video.track")
        var finalBytes = 0L
        downloadTrack(client,"https://fixture.bilivideo.com/video",file) { bytes,total -> finalBytes=bytes; assertEquals(10L,total) }
        assertEquals("abcdefghij",file.readText()); assertEquals(10L,finalBytes)
    }
    @Test fun chunkedResumeRequiresTheSameStrongValidatorAndKeepsItsPrefix() = fixture { directory ->
        val file = File(directory,"video.track").apply { writeText("abcd") }
        File(directory,"video.track.range").writeText("\"same\"\n10")
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            assertEquals("bytes=4-",chain.request().header("Range"))
            assertEquals("\"same\"",chain.request().header("If-Range"))
            response(chain.request(),"efghij",range="bytes 4-9/10",etag="\"same\"")
        }.build()
        downloadTrack(client,"https://fixture.bilivideo.com/video",file) { _,_ -> }
        assertEquals("abcdefghij",file.readText())
    }
    @Test fun truncatedStreamCannotBeReportedAsComplete() = fixture { directory ->
        val client = OkHttpClient.Builder().addInterceptor { response(it.request(),"abc") }.build()
        try { downloadTrack(client,"https://fixture.bilivideo.com/video",File(directory,"video.track")) { _,_ -> }; fail() }
        catch (_: IOException) { }
    }
    @Test fun longerStreamCannotBeReportedAsComplete() = fixture { directory ->
        val client = OkHttpClient.Builder().addInterceptor { response(it.request(),"abcdefghijk") }.build()
        try { downloadTrack(client,"https://fixture.bilivideo.com/video",File(directory,"video.track")) { _,_ -> }; fail() }
        catch (e: BiliFailure) { assertTrue(e.message!!.contains("超过")) }
    }
    @Test fun httpFailureRetainsItsStatusAndNeverCreatesAMediaFile() = fixture { directory ->
        val client = OkHttpClient.Builder().addInterceptor { response(it.request(),"denied",code=403) }.build()
        val file = File(directory,"video.track")
        try { downloadTrack(client,"https://fixture.bilivideo.com/video",file) { _,_ -> }; fail() }
        catch (e: BiliFailure) { assertTrue(e.message!!.contains("HTTP 403")) }
        assertFalse(file.exists())
    }
}

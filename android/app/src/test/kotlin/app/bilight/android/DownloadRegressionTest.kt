package app.bilight.android

import app.bilight.android.core.*
import app.bilight.android.downloads.*
import org.junit.Assert.*
import org.junit.Test

class DownloadRegressionTest {
    @Test fun resumesOnlyTheSameCompleteByteRange() {
        val previous = ByteResume("\"same-file\"", 100)
        assertEquals(previous, ByteResume.validate(206, 40, 60, "bytes 40-99/100", "\"same-file\"", previous))
        for ((code, range, etag) in listOf(Triple(200, null, "\"same-file\""), Triple(206, "bytes 40-99/100", "\"another-file\""), Triple(206, "bytes 41-99/100", "\"same-file\""), Triple(206, "bytes 40-99/100", "W/\"same-file\""))) {
            try { ByteResume.validate(code, 40, 60, range, etag, previous); fail("Must reject changed or mismatched bytes") }
            catch (e: BiliFailure) { assertEquals("RESUME_CHANGED", e.code) }
        }
    }
    @Test fun weakOrMissingEtagCannotAuthorizeAppending() {
        assertNull(ByteResume.strong("W/\"abc\"")); assertNull(ByteResume.strong(null))
        try { ByteResume.validate(206, 40, 60, "bytes 40-99/100", null, ByteResume("",100)); fail() }
        catch (e: BiliFailure) { assertEquals("RESUME_CHANGED", e.code) }
    }
    @Test fun initialPartialResponseCannotPretendToBeACompleteFile() {
        try { ByteResume.validate(206, 0, 100, "bytes 0-99/1000", "\"abc\"", null); fail() }
        catch (e: BiliFailure) { assertTrue(e.message!!.contains("范围")) }
        assertEquals(100L, ByteResume.validate(200,0,100,null,null,null).total)
    }
    @Test fun privateManifestRoundTripKeepsPartAndQualityWithoutMediaTokens() {
        val video = Video("BV1NGZtBwELa", 42, "隔离测试", null, 120, 0, User(1,"演示",null),0)
        val item = DownloadRecord("12345678-1234-1234-1234-123456789abc",video,Part(84,2,"第二部分",120),120,"4K",DownloadState.PAUSED,40,100)
        val bytes = encodeDownloads(listOf(item))
        assertEquals(listOf(item), decodeDownloads(bytes))
        assertFalse(String(bytes).contains("SESSDATA")); assertFalse(String(bytes).contains("deadline"))
    }
    @Test fun manifestCannotEscapeItsOwnedDirectory() {
        val video = Video("BV1NGZtBwELa",42,"测试",null,120,0,User(1,"演示",null),0)
        val raw = DownloadRecord("12345678-1234-1234-1234-123456789abc",video,Part(1,1,"P1",120),80,"1080P").json().put("id","../other")
        try { DownloadRecord.parse(raw); fail() } catch (_: IllegalArgumentException) { }
    }
}

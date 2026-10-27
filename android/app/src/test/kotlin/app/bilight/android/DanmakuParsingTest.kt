package app.bilight.android

import app.bilight.android.core.BiliFailure
import app.bilight.android.playback.Danmaku
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import java.util.zip.GZIPOutputStream

class DanmakuParsingTest {
    private val xml="""<i><d p="2,1,25,16777215">中文弹幕 &amp; 测试</d><d p="1,5,25,16777215">顶部</d></i>""".toByteArray()
    private fun deflate(bytes: ByteArray,raw: Boolean): ByteArray {
        val output=ByteArrayOutputStream(); val compressor=Deflater(Deflater.DEFAULT_COMPRESSION,raw)
        try { DeflaterOutputStream(output,compressor).use { it.write(bytes) }; return output.toByteArray() }
        finally { compressor.end() }
    }
    private fun gzip(bytes: ByteArray)=ByteArrayOutputStream().also { output -> GZIPOutputStream(output).use { it.write(bytes) } }.toByteArray()
    @Test fun readsRawDeflateWithoutSendingCompressedBytesToTheXmlParser() {
        val values=Danmaku.parse(deflate(xml,true))
        assertEquals(listOf("顶部","中文弹幕 & 测试"),values.map { it.text })
    }
    @Test fun readsZlibAndGzipResponsesAsTheSameComments() {
        val expected=Danmaku.parse(xml)
        for (bytes in listOf(deflate(xml,false),gzip(xml))) assertEquals(expected,Danmaku.parse(bytes))
    }
    @Test fun corruptedOrTruncatedStreamsAreFailuresRatherThanEmptySuccess() {
        for (bytes in listOf(byteArrayOf(1,2,3,4),deflate(xml,true).dropLast(3).toByteArray(),deflate(xml,false).dropLast(2).toByteArray(),gzip(xml).dropLast(4).toByteArray())) {
            val error=assertThrows(BiliFailure::class.java) { Danmaku.parse(bytes) }
            assertTrue(error.message.orEmpty().contains("弹幕"))
        }
    }
    @Test fun decompressionAndInputBothHaveABoundedSize() {
        for (bytes in listOf(ByteArray(8_000_001),deflate(ByteArray(8_000_001) { 32 },true))) {
            assertTrue(assertThrows(BiliFailure::class.java) { Danmaku.parse(bytes) }.message.orEmpty().contains("过大"))
        }
    }
    @Test fun compressedEntityDeclarationsRemainRejected() {
        val unsafe="""<!DOCTYPE i [<!ENTITY leak SYSTEM "file:///data/local/file">]><i>&leak;</i>""".toByteArray()
        for (bytes in listOf(unsafe,deflate(unsafe,true),deflate(unsafe,false),gzip(unsafe))) {
            assertTrue(assertThrows(BiliFailure::class.java) { Danmaku.parse(bytes) }.message.orEmpty().contains("不安全"))
        }
    }
    @Test fun malformedXmlDoesNotExposeParserInternals() {
        for (bytes in listOf("<i><d>broken".toByteArray(),"<html>unavailable</html>".toByteArray(),byteArrayOf(0xff.toByte(),0xfe.toByte())+"<i/>".toByteArray(Charsets.UTF_16LE))) {
            val error=assertThrows(BiliFailure::class.java) { Danmaku.parse(bytes) }
            assertTrue(error.message.orEmpty().contains("弹幕")); assertFalse(error.message.orEmpty().contains("Unexpected")); assertFalse(error.message.orEmpty().contains("java."))
        }
    }
    @Test fun genuineEmptyXmlAndUtf8BomRemainValid() {
        assertTrue(Danmaku.parse("<i/>".toByteArray()).isEmpty())
        assertEquals(Danmaku.parse(xml),Danmaku.parse(byteArrayOf(0xef.toByte(),0xbb.toByte(),0xbf.toByte())+xml))
    }
    @Test fun platformErrorCodeIsPreservedInsteadOfBecomingAnXmlException() {
        val error=assertThrows(BiliFailure::class.java) { Danmaku.parse("""{"code":-352,"message":"需要安全验证"}""".toByteArray()) }
        assertEquals("-352",error.code); assertTrue(error.message.orEmpty().contains("-352"))
    }
}

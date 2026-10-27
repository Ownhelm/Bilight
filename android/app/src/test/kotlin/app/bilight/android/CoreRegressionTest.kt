package app.bilight.android

import app.bilight.android.core.*
import app.bilight.android.playback.Danmaku
import app.bilight.android.playback.dashManifest
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CoreRegressionTest {
    @Test fun portraitDimensionsSurviveDetailAndDownloadMetadata() {
        val video=Video.parse(JSONObject("""{"bvid":"BV1NGZtBwELa","aid":42,"title":"竖屏测试","dimension":{"width":1080,"height":1920}}"""))!!
        assertEquals(1080,video.width); assertEquals(1920,video.height)
        assertNull(bvidFrom("BV1NGZtBwELax")); assertEquals("BV1NGZtBwELa",bvidFrom("https://www.bilibili.com/video/BV1NGZtBwELa?p=2"))
    }
    @Test fun articleCardAndReadonlyDynamicCountsComeFromTheActualPayload() {
        val raw=JSONObject("""{"id_str":"1262431200618741810","type":"DYNAMIC_TYPE_ARTICLE","modules":{"module_author":{"mid":42,"name":"演示作者"},"module_dynamic":{"major":{"type":"MAJOR_TYPE_ARTICLE","article":{"title":"专栏标题","desc":"原文摘要","covers":["https://i0.hdslb.com/cover.jpg"],"jump_url":"https://www.bilibili.com/read/cv123"}}},"module_stat":{"forward":{"count":3},"like":{"count":8,"status":true},"comment":{"count":4}}}}""")
        val post=Post.parse(raw)!!
        assertEquals("专栏标题",post.link!!.title); assertEquals("原文摘要",post.link!!.summary); assertEquals("专栏",post.link!!.label)
        assertEquals(3L,post.forwards); assertEquals(8L,post.likes); assertTrue(post.liked)
    }
    @Test fun unavailableQualityFallsDownWithoutMutatingThePreference() {
        assertEquals(80,selectQuality(listOf(32,80,112),100))
        assertEquals(32,selectQuality(listOf(80,32),16))
        assertEquals(120,selectQuality(listOf(80,120,64),120))
        assertEquals(120,selectQuality(listOf(80,120),127))
    }
    @Test fun doubleTapBoundariesUseFortyTwentyForty() {
        assertEquals(TapZone.BACKWARD,tapZone(.3999f)); assertEquals(TapZone.TOGGLE,tapZone(.4f)); assertEquals(TapZone.TOGGLE,tapZone(.5999f)); assertEquals(TapZone.FORWARD,tapZone(.6f))
    }
    @Test fun origNullIsNotMistakenForAnInsertedOriginal() {
        val raw=JSONObject("""{"id_str":"1262431200618741810","type":"DYNAMIC_TYPE_WORD","orig":null,"modules":{"module_author":{"mid":42,"name":"演示作者"},"module_dynamic":{"desc":{"text":"真实文字动态"}}}}""")
        val post=Post.parse(raw)
        assertNotNull(post); assertEquals("1262431200618741810",post!!.id); assertEquals("真实文字动态",post.text)
        raw.put("orig",JSONObject().put("id_str","another-author")); assertNull(Post.parse(raw))
    }
    @Test fun advertisementsAreNotFollowedContent() {
        val raw=JSONObject("""{"id_str":"123","type":"DYNAMIC_TYPE_WORD","modules":{"module_author":{"mid":42},"module_ad":{"source":"inserted"}}}""")
        assertNull(Post.parse(raw))
    }
    @Test fun mediaCannotEscapeTheAllowedHttpsCdn() {
        assertNull(mediaUrl("https://example.org/private")); assertNull(mediaUrl("https://evilbilivideo.com/file")); assertNull(mediaUrl("https://user:secret@a.bilivideo.com/file")); assertNull(mediaUrl("https://a.bilivideo.com:1234/file"))
        assertEquals("https://a.bilivideo.com/file",mediaUrl("http://a.bilivideo.com/file"))
    }
    @Test fun wbiEncodingAndSigningAreStable() {
        assertEquals("%E4%BD%A0%E5%A5%BD%20%2A",BiliHttp.encode("你好 *"))
        val result=BiliHttp.signedQuery(mapOf("foo" to "a!b(c)*","w_rid" to "old"),"key",100)
        assertTrue(result.startsWith("foo=abc&wts=100&w_rid=")); assertEquals(32,result.substringAfter("w_rid=").length)
        assertEquals(result,BiliHttp.signedQuery(linkedMapOf("w_rid" to "ignored","foo" to "abc"),"key",100))
    }
    @Test fun plainDanmakuPreservesGlyphsAndOrdering() {
        val values=Danmaku.parse("""<i><d p="2,1,25,0">中文细笔画 &amp; 测试</d><d p="1,5,25,16777215">顶部</d></i>""".toByteArray())
        assertEquals(listOf("顶部","中文细笔画 & 测试"),values.map { it.text })
    }
    @Test fun xmlExternalEntitiesAreRejectedBeforeParsing() {
        try { Danmaku.parse("""<!DOCTYPE i [<!ENTITY leak SYSTEM "file:///data/local/file">]><i>&leak;</i>""".toByteArray()); fail("Untrusted XML must be rejected") } catch (e: BiliFailure) { assertTrue(e.message!!.contains("不安全")) }
    }
    @Test fun dashManifestKeepsAudioAndVideoAsSeparateByteSources() {
        val video=Track(80,"https://a.bilivideo.com/video?x=1&y=2","avc1.640028",1000000,1920,1080,"0-999","1000-1999")
        val audio=Track(30280,"https://a.bilivideo.com/audio","mp4a.40.2",128000,0,0,"0-599","600-1000")
        val manifest=dashManifest(Playback(80,listOf(Quality(80,"1080P")),120.0,video,audio,null))
        assertTrue(manifest.contains("x=1&amp;y=2")); assertTrue(manifest.contains("contentType=\"audio\"")); assertTrue(manifest.contains("indexRange=\"1000-1999\"")); assertFalse(manifest.contains("Cookie"))
    }
}

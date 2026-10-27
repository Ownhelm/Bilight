package app.bilight.android

import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.*
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Explicit opt-in read in this App's own session. Never exports credentials, authors or cursors. */
class LiveFollowingReadTest {
    @Test fun continuedPagesCanBeReadWithoutExportingAccountData() = runBlocking {
        val args=InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("liveFollowingRead")=="true" && args.getString("allowAccountRead")=="true")
        val http=ApplicationProvider.getApplicationContext<BilightApplication>().http
        check(http.restore()!=null) { "请先在 Bilight 内登录后再进行真实关注读取验收。" }
        http.ensureAccount();http.ensureDevice()
        val raw=http.request("/x/polymer/web-dynamic/v1/feed/all",mapOf("type" to "all","platform" to "web","features" to "itemOpusStyle,opusBigCover,ugcDelete"))
        val flag=raw.opt("has_more")
        val sourceMore=when(flag) { is Boolean -> flag;is Number -> flag.toInt()==1;else -> error("Unexpected continuation flag type") }
        val repository=BiliRepository(http)
        val pages=JSONArray();var cursor: String?=null
        for(index in 1..3) {
            val page=repository.following(cursor)
            if(index==1) assertEquals("The real continuation was lost in the production adapter",sourceMore,page.more)
            pages.put(JSONObject().put("page",index).put("has_more",page.more).put("verified_post_count",page.items.size))
            if(!page.more) break
            assertTrue(!page.cursor.isNullOrEmpty() && page.cursor!=cursor);cursor=page.cursor
        }
        InstrumentationRegistry.getInstrumentation().sendStatus(0,android.os.Bundle().apply {
            putString("stream","BILIGHT_FOLLOWING_READ "+JSONObject().put("source_flag_type",flag.javaClass.simpleName).put("pages",pages).toString()+"\n")
        })
        assertTrue(pages.length()>0)
    }
}

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

/** Opt-in reads using only Bilight's own session; outputs counts and shapes, never account content. */
class LiveFavoritesReadTest {
    private fun report(value: JSONObject) {
        InstrumentationRegistry.getInstrumentation().sendStatus(0,android.os.Bundle().apply { putString("stream","BILIGHT_FAVORITES_READ $value\n") })
    }
    @Test fun collectedDirectoryAndAvailableContentsCanBeRead() = runBlocking {
        val args=InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("liveFavoritesRead")=="true" && args.getString("allowAccountRead")=="true")
        val http=ApplicationProvider.getApplicationContext<BilightApplication>().http
        check(http.restore()!=null) { "请先在 Bilight 内登录后进行收藏只读验收。" }
        val uid=http.ensureAccount(); val repository=BiliRepository(http)
        val raw=http.request("/x/v3/fav/folder/collected/list",mapOf("up_mid" to "$uid","pn" to "1","ps" to "20","platform" to "web"))
        val rows=raw.rows("list")
        report(JSONObject().put("stage","directory_shape").put("reported_count",raw.optInt("count"))
            .put("items",rows.size).put("invalid_id",rows.count { it.optLong("id")<=0 })
            .put("missing_title",rows.count { it.opt("title") !is String }).put("missing_count",rows.count { it.opt("media_count") !is Number })
            .put("missing_owner",rows.count { it.optLong("mid")<=0 && it.obj("upper").optLong("mid")<=0 }))
        val contents=JSONArray(); val pages=JSONArray(); val opened=mutableSetOf<Int>()
        for (number in 1..3) {
            val page=repository.folders(true,number)
            pages.put(JSONObject().put("page",number).put("items",page.items.size).put("has_more",page.more).put("incomplete",page.items.count { it.readError!=null }).put("unavailable",page.items.count { it.unavailable }))
            for (folder in page.items.filter { !it.unavailable && it.type in listOf(11,21) && it.type !in opened }.distinctBy { it.type }) {
                val result=repository.folderVideos(folder,1); opened+=folder.type
                contents.put(JSONObject().put("type",folder.type).put("videos",result.items.size).put("has_more",result.more))
            }
            if (!page.more) break
        }
        report(JSONObject().put("stage","read_complete").put("pages",pages).put("contents",contents))
        assertTrue(pages.length()>0)
    }
}

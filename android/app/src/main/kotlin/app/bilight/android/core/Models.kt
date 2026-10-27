package app.bilight.android.core

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

class BiliFailure(val code: String, message: String) : Exception(message)
fun invalid(message: String = "B站返回的数据不完整，请重试。"): Nothing = throw BiliFailure("INVALID_RESPONSE", message)
fun JSONObject.obj(key: String): JSONObject = optJSONObject(key) ?: JSONObject()
fun JSONObject.rows(key: String): List<JSONObject> = optJSONArray(key)?.objects().orEmpty()
fun JSONArray.objects(): List<JSONObject> = (0 until length()).mapNotNull { optJSONObject(it) }
fun clean(value: String, limit: Int = 30000): String = value.replace(Regex("(?is)<(script|style)\\b[^>]*>.*?</\\1>"), "").replace(Regex("<[^>]*>"), "").replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'").replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">").trim().take(limit)
fun JSONObject.text(key: String, fallback: String = ""): String = if (isNull(key)) fallback else clean(optString(key, fallback))
fun validBvid(value: String): Boolean = Regex("^BV[0-9A-Za-z]{10}$").matches(value)
fun bvidFrom(value: String): String? = Regex("(?<![0-9A-Za-z])BV[0-9A-Za-z]{10}(?![0-9A-Za-z])").find(value)?.value
fun secureUrl(raw: String): String? {
    val value = if (raw.startsWith("//")) "https:$raw" else raw
    val url = value.toHttpUrlOrNull() ?: return null
    val allowed = listOf("hdslb.com", "bilivideo.com", "bilivideo.cn", "bilibili.com", "b23.tv").any { url.host == it || url.host.endsWith(".$it") }
    if (!allowed || url.username.isNotEmpty() || url.password.isNotEmpty() || url.port !in listOf(80, 443)) return null
    return url.newBuilder().scheme("https").port(443).build().toString()
}
fun mediaUrl(raw: String): String? = secureUrl(raw)?.takeIf { value ->
    val host = value.toHttpUrlOrNull()!!.host
    listOf("hdslb.com", "bilivideo.com", "bilivideo.cn").any { host == it || host.endsWith(".$it") }
}
fun duration(raw: String): Long = if (raw.contains(':')) raw.split(':').fold(0L) { sum, v -> sum * 60 + (v.toLongOrNull() ?: 0) } else raw.toDoubleOrNull()?.toLong() ?: 0
fun clock(seconds: Long): String = seconds.coerceAtLeast(0).let { if (it >= 3600) "%d:%02d:%02d".format(it / 3600, it / 60 % 60, it % 60) else "%d:%02d".format(it / 60, it % 60) }
fun count(value: Long): String = when { value >= 100000000 -> String.format(Locale.CHINA, "%.1f亿", value / 1e8); value >= 10000 -> String.format(Locale.CHINA, "%.1f万", value / 1e4); else -> value.toString() }
fun number(value: String): Long = ((value.replace("万", "").replace("亿", "").toDoubleOrNull() ?: 0.0) * when { value.contains("亿") -> 1e8; value.contains("万") -> 1e4; else -> 1.0 }).toLong()

data class User(val mid: Long, val name: String, val avatar: String?, val sign: String = "", val fans: Long = 0) {
    companion object { fun parse(raw: JSONObject) = User(raw.optLong("mid", raw.optLong("uid")), raw.text("name", raw.text("uname")), secureUrl(raw.text("face", raw.text("avatar", raw.text("upic")))), raw.text("sign", raw.text("usign")), raw.optLong("fans")) }
}
data class Video(val bvid: String, val aid: Long, val title: String, val cover: String?, val duration: Long, val published: Long, val owner: User, val views: Long, val width: Int = 0, val height: Int = 0) {
    companion object { fun parse(raw: JSONObject, owner: User? = null): Video? {
        val bvid = raw.text("bvid"); if (!validBvid(bvid)) return null
        return Video(bvid, raw.optLong("aid", raw.optLong("id")), raw.text("title"), secureUrl(raw.text("pic", raw.text("cover"))), duration(raw.text("duration", raw.text("length", raw.text("duration_text")))), raw.optLong("pubdate", raw.optLong("created")), raw.optJSONObject("owner")?.let(User::parse) ?: owner ?: User(raw.optLong("mid"), raw.text("author"), secureUrl(raw.text("upic"))), number(raw.text("play", raw.obj("stat").text("view", raw.obj("stat").text("play")))), raw.obj("dimension").optInt("width"), raw.obj("dimension").optInt("height"))
    } }
}
data class Part(val cid: Long, val page: Int, val title: String, val duration: Long, val width: Int = 0, val height: Int = 0)
data class Statistics(val likes: Long, val coins: Long, val favorites: Long)
data class Detail(val video: Video, val parts: List<Part>, val description: String, val coinLimit: Int, val statistics: Statistics)
data class Page<T>(val items: List<T>, val more: Boolean, val cursor: String? = null)
data class Relation(val following: Boolean, val mutual: Boolean, val blocked: Boolean) {
    companion object { fun parse(raw: JSONObject): Relation { if (!raw.has("attribute")) invalid(); val a = raw.getInt("attribute"); return Relation(a in listOf(1,2,6), a == 6, a >= 128) } }
}
data class Collection(val id: Long, val mid: Long, val series: Boolean, val title: String, val cover: String?, val total: Int) {
    companion object { fun parse(raw: JSONObject, mid: Long, series: Boolean): Collection { val m = raw.obj("meta"); val id = m.optLong(if (series) "series_id" else "season_id"); if (id <= 0 || m.optLong("mid") != mid) invalid("合集与当前UP主不匹配。"); return Collection(id, mid, series, m.text("name", m.text("title")), secureUrl(m.text("cover", raw.rows("archives").firstOrNull()?.text("pic").orEmpty())), m.optInt("total", m.optInt("count"))) } }
}
data class Picture(val url: String, val width: Int, val height: Int)
data class PostLink(val title: String, val summary: String, val cover: String?, val url: String?, val label: String)
data class Post(val id: String, val author: User, val published: Long, val action: String, val text: String, val title: String, val video: Video? = null, val pictures: List<Picture> = emptyList(), val original: Post? = null, val link: PostLink? = null, val unavailable: String? = null, val commentId: String? = null, val commentType: Int = 0, val comments: Long = 0, val forwards: Long = 0, val likes: Long = 0, val liked: Boolean = false) {
    companion object { fun parse(raw: JSONObject, depth: Int = 0): Post? {
        val modules = raw.obj("modules"); val a = modules.obj("module_author"); val id = raw.text("id_str"); val type = raw.text("type")
        if (!Regex("^[1-9][0-9]{0,31}$").matches(id) || a.optLong("mid") <= 0 || depth >= 3 || !type.startsWith("DYNAMIC_TYPE_") || type in listOf("DYNAMIC_TYPE_AD", "DYNAMIC_TYPE_BANNER") || !modules.isNull("module_ad")) return null
        val forward = type == "DYNAMIC_TYPE_FORWARD"
        // Non-forward responses legitimately contain orig:null; only an actual embedded original is rejected.
        if (!forward && !raw.isNull("orig")) return null
        val author = User.parse(a); val dynamic = modules.obj("module_dynamic"); val major = dynamic.obj("major"); val opus = major.obj("opus"); val basic = raw.obj("basic")
        val archive = major.optJSONObject("archive") ?: major.optJSONObject("ugc_season")
        if (archive?.optJSONObject("owner")?.optLong("mid")?.let { it != author.mid } == true) return null
        val video = archive?.let { if (!validBvid(it.text("bvid"))) bvidFrom(it.text("jump_url"))?.let { bv -> it.put("bvid", bv) }; Video.parse(it, author) }
        val photos = (if (major.text("type") == "MAJOR_TYPE_DRAW") major.obj("draw").rows("items") else opus.rows("pics")).mapNotNull { p -> secureUrl(p.text("src", p.text("url")))?.let { Picture(it, p.optInt("width"), p.optInt("height")) } }.distinctBy { it.url }
        val original = if (forward) parse(raw.obj("orig"), depth + 1) else null
        val article = major.obj("article")
        val key=major.text("type").removePrefix("MAJOR_TYPE_").lowercase()
        var card=if (key=="article") article else major.obj(key)
        if (key=="live_rcmd") card=runCatching { JSONObject(card.getString("content")).obj("live_play_info") }.getOrDefault(JSONObject())
        val cardTitle=card.text("title",card.text("name")); val cardText=card.text("desc",card.text("summary"))
        val link=if (video==null && photos.isEmpty() && key !in listOf("","none","blocked","opus") && (cardTitle.isNotEmpty() || cardText.isNotEmpty())) {
            PostLink(cardTitle,cardText,secureUrl(if (key=="article") card.optJSONArray("covers")?.optString(0).orEmpty() else card.text("cover")),secureUrl(card.text("jump_url")),if (key=="article") "专栏" else if (key.contains("live")) "直播动态" else "动态")
        } else null
        val stats=modules.obj("module_stat")
        val warning=if (forward && original==null) "原动态已失效或暂时无法查看" else if (key=="none") major.obj("none").text("tips","内容暂时无法查看") else if (!forward && video==null && photos.isEmpty() && link==null && key !in listOf("","opus")) "附加内容暂时无法展示" else null
        return Post(id, author, a.optLong("pub_ts"), a.text("pub_action"), dynamic.obj("desc").text("text", opus.obj("summary").text("text")), opus.text("title"), video, photos, original, link, warning, basic.text("comment_id_str").takeIf { Regex("^[1-9][0-9]{0,31}$").matches(it) }, basic.optInt("comment_type"), stats.obj("comment").optLong("count"),stats.obj("forward").optLong("count"),stats.obj("like").optLong("count"),stats.obj("like").optBoolean("status"))
    } }
}
data class Track(val id: Int, val url: String, val codecs: String, val bandwidth: Long, val width: Int, val height: Int, val initialization: String, val indexRange: String) {
    companion object { fun parse(r: JSONObject): Track? {
        val url = mediaUrl(r.text("baseUrl", r.text("base_url"))) ?: return null
        val segment = r.optJSONObject("SegmentBase") ?: r.obj("segment_base")
        val init = segment.text("Initialization", segment.text("initialization")); val index = segment.text("indexRange", segment.text("index_range"))
        if (!Regex("^\\d+-\\d+$").matches(init) || !Regex("^\\d+-\\d+$").matches(index)) return null
        return Track(r.optInt("id"), url, r.text("codecs"), r.optLong("bandwidth"), r.optInt("width"), r.optInt("height"), init, index)
    } }
}
data class Quality(val id: Int, val label: String)
data class Playback(val quality: Int, val qualities: List<Quality>, val duration: Double, val video: Track?, val audio: Track?, val mp4: String?)
fun selectQuality(available: List<Int>, preferred: Int): Int = available.filter { it <= preferred }.maxOrNull() ?: available.minOrNull() ?: throw BiliFailure("NO_QUALITY", "没有可用画质。")
enum class TapZone { BACKWARD, TOGGLE, FORWARD }
fun tapZone(fraction: Float): TapZone = when { fraction < .4f -> TapZone.BACKWARD; fraction < .6f -> TapZone.TOGGLE; else -> TapZone.FORWARD }
data class Subtitle(val id: Long, val language: String, val label: String, val url: String)
data class Cue(val from: Double, val to: Double, val text: String)
data class Comment(val id: String, val user: User, val text: String, val likes: Long)
data class History(val video: Video, val cid: Long, val page: Int, val part: String, val progress: Long, val viewedAt: Long, val completed: Boolean)
data class Folder(val id: Long, val mid: Long, val title: String, val count: Int, val private: Boolean, val selected: Boolean = false, val capacity: Int = 1000, val cover: String? = null)
data class Engagement(val liked: Boolean, val coins: Int, val favorite: Boolean) { val complete: Boolean get() = liked && coins > 0 && favorite }

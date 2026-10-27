package app.bilight.android.downloads

import app.bilight.android.core.*
import org.json.JSONArray
import org.json.JSONObject

enum class DownloadState(val label: String) {
    QUEUED("等待下载"), RESOLVING("正在准备"), DOWNLOADING("正在下载"),
    PAUSED("已暂停"), MERGING("正在合并"), COMPLETED("已完成"), FAILED("下载失败");
    val active: Boolean get() = this in listOf(QUEUED, RESOLVING, DOWNLOADING, MERGING)
}
data class DownloadRecord(
    val id: String, val video: Video, val part: Part, val quality: Int, val label: String,
    val state: DownloadState = DownloadState.QUEUED, val received: Long = 0,
    val total: Long = 0, val error: String? = null
) {
    fun json(): JSONObject = JSONObject().put("id", id).put("video", JSONObject()
        .put("bvid", video.bvid).put("aid", video.aid).put("title", video.title)
        .put("pic", video.cover).put("duration", video.duration).put("pubdate", video.published)
        .put("dimension", JSONObject().put("width",video.width).put("height",video.height))
        .put("owner", JSONObject().put("mid", video.owner.mid).put("name", video.owner.name).put("face", video.owner.avatar)))
        .put("part", JSONObject().put("cid", part.cid).put("page", part.page).put("title", part.title).put("duration", part.duration).put("width",part.width).put("height",part.height))
        .put("quality", quality).put("label", label).put("state", state.name)
        .put("received", received).put("total", total).put("error", error)
    companion object {
        fun parse(raw: JSONObject): DownloadRecord {
            val id = raw.getString("id")
            require(Regex("^[a-f0-9-]{36}$").matches(id))
            val p = raw.getJSONObject("part")
            require(p.getLong("cid") > 0 && p.getInt("page") > 0)
            return DownloadRecord(id, Video.parse(raw.getJSONObject("video")) ?: invalid(),
                Part(p.getLong("cid"), p.getInt("page"), p.getString("title"), p.getLong("duration"),p.optInt("width"),p.optInt("height")),
                raw.getInt("quality"), raw.getString("label"), DownloadState.valueOf(raw.getString("state")),
                raw.optLong("received"), raw.optLong("total"), raw.text("error").takeIf { it.isNotEmpty() })
        }
    }
}

/** A resumed response must prove that its prefix belongs to exactly the same byte file. */
data class ByteResume(val etag: String, val total: Long) {
    companion object {
        fun strong(value: String?): String? = value?.takeIf { it.startsWith('"') && it.endsWith('"') && !it.startsWith("W/") }
        fun validate(code: Int, offset: Long, length: Long, range: String?, etag: String?, previous: ByteResume?): ByteResume {
            if (length <= 0) invalid("下载响应缺少有效长度。")
            if (offset == 0L) {
                if (code != 200 && code != 206) invalid("下载失败（HTTP $code）。")
                if (code == 206 && range != "bytes 0-${length - 1}/$length") invalid("下载范围不完整，请重试。")
                return ByteResume(strong(etag).orEmpty(), length)
            }
            if (code != 206 || previous == null || previous.etag.isEmpty() || strong(etag) != previous.etag ||
                previous.total != offset + length || range != "bytes $offset-${previous.total - 1}/${previous.total}") {
                throw BiliFailure("RESUME_CHANGED", "下载源已变化，请重新下载，避免文件损坏。")
            }
            return previous
        }
    }
}

fun encodeDownloads(items: List<DownloadRecord>): ByteArray = JSONArray(items.map { it.json() }).toString().toByteArray()
fun decodeDownloads(bytes: ByteArray): List<DownloadRecord> = JSONArray(String(bytes)).objects().map(DownloadRecord::parse)

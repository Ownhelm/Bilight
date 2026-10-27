package app.bilight.android.core

import android.util.Base64
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

sealed interface VideoWrite {
    data class Like(val selected: Boolean): VideoWrite
    data class Coin(val target: Int, val like: Boolean): VideoWrite
    data class Favorite(val ids: Set<Long>): VideoWrite
    data object Triple: VideoWrite
}
class BiliRepository(val http: BiliHttp) {
    private val relationCache = ConcurrentHashMap<Long,Pair<Relation,Long>>()
    private var relationVersion = -1L
    @Volatile private var relationEpoch = 0L
    private val followLocks = ConcurrentHashMap<Long,Mutex>()
    private val videoLocks = ConcurrentHashMap<String,Mutex>()
    private val uncertain = ConcurrentHashMap<String,Long>()
    fun invalidateFollowing() { relationEpoch++; relationCache.clear(); relationVersion = http.generation }
    private suspend fun account(): Long = http.ensureAccount()
    suspend fun search(keyword: String, users: Boolean, page: Int): Page<Any> {
        http.ensureDevice()
        val data = http.request("/x/web-interface/wbi/search/type", mapOf("keyword" to keyword,"search_type" to if (users) "bili_user" else "video","page" to "$page","page_size" to "30","order" to if (users) "0" else "totalrank"),wbi=true)
        if (data.optJSONArray("result") == null) invalid()
        val rows = data.rows("result")
        val items: List<Any> = if (users) rows.map(User::parse).filter { it.mid > 0 } else rows.mapNotNull { Video.parse(it) }.distinctBy { it.bvid }
        return Page(items, if (data.optInt("numPages") > 0) page < data.getInt("numPages") else page*30 < data.optInt("numResults"))
    }
    suspend fun creator(mid: Long): User {
        http.ensureDevice(); val data = http.request("/x/space/wbi/acc/info",mapOf("mid" to "$mid"),wbi=true,referer="https://space.bilibili.com/$mid")
        if (data.optLong("mid") != mid) invalid(); return User.parse(data)
    }
    suspend fun creatorVideos(owner: User, page: Int): Page<Video> {
        val data = http.request("/x/space/wbi/arc/search",mapOf("mid" to "${owner.mid}","pn" to "$page","ps" to "30","order" to "pubdate","tid" to "0","keyword" to "","platform" to "web","web_location" to "1550101","order_avoided" to "true"),wbi=true,referer="https://space.bilibili.com/${owner.mid}/upload/video")
        if (data.obj("list").optJSONArray("vlist") == null) invalid()
        return Page(data.obj("list").rows("vlist").mapNotNull { Video.parse(it,owner) }.distinctBy { it.bvid },page*30 < data.obj("page").optInt("count"))
    }
    suspend fun collections(mid: Long, page: Int): Page<Collection> {
        val data = http.request("/x/polymer/web-space/seasons_series_list",mapOf("mid" to "$mid","page_num" to "$page","page_size" to "12"),referer="https://space.bilibili.com/$mid/lists").obj("items_lists")
        if (data.optJSONArray("seasons_list") == null || data.optJSONArray("series_list") == null || !data.obj("page").has("total")) invalid("合集和列表暂时无法完整读取，请重试。")
        return Page(data.rows("seasons_list").map { Collection.parse(it,mid,false) } + data.rows("series_list").map { Collection.parse(it,mid,true) }, page*data.obj("page").optInt("page_size",12) < data.obj("page").optInt("total"))
    }
    suspend fun collection(owner: User, collection: Collection, page: Int): Page<Video> = coroutineScope {
        val data: JSONObject; val metadata: JSONObject
        if (!collection.series) {
            data = http.request("/x/polymer/web-space/seasons_archives_list",mapOf("mid" to "${owner.mid}","season_id" to "${collection.id}","sort_reverse" to "false","page_num" to "$page","page_size" to "30")); metadata = data
        } else {
            val info = async { http.request("/x/series/series",mapOf("series_id" to "${collection.id}")) }
            val videos = async { http.request("/x/series/archives",mapOf("mid" to "${owner.mid}","series_id" to "${collection.id}","only_normal" to "true","sort" to "desc","pn" to "$page","ps" to "30")) }
            metadata = info.await(); data = videos.await()
        }
        if (Collection.parse(metadata,owner.mid,collection.series).id != collection.id || data.optJSONArray("archives") == null) invalid()
        Page(data.rows("archives").mapNotNull { Video.parse(it,owner) }.distinctBy { it.bvid },page*data.obj("page").optInt("page_size",data.obj("page").optInt("size",30)).coerceAtLeast(1) < data.obj("page").optInt("total",collection.total))
    }
    suspend fun relation(mid: Long): Relation { account(); return Relation.parse(http.request("/x/relation",mapOf("fid" to "$mid"))) }
    suspend fun follow(mid: Long, desired: Boolean): Relation {
        val mutex = followLocks.getOrPut(mid) { Mutex() }
        if (!mutex.tryLock()) throw BiliFailure("BUSY","关注操作正在处理中。")
        try {
            val uid = account(); if (uid == mid) throw BiliFailure("SELF_FOLLOW","不能关注自己。")
            val version = http.generation; val before = relation(mid)
            if (before.following == desired) { invalidateFollowing(); return before }
            if (before.blocked) throw BiliFailure("BLOCKED","请先在B站解除拉黑。")
            http.ensureDevice(); http.check(version)
            http.request("/x/relation/modify",form=mapOf("fid" to "$mid","act" to if (desired) "1" else "2","re_src" to "11","csrf" to http.csrf()))
            invalidateFollowing()
            for (wait in listOf(0L,150L,350L)) { delay(wait); val after = relation(mid); http.check(version); if (after.following == desired) return after }
            throw BiliFailure("FOLLOW_UNCONFIRMED","关注请求已提交，请刷新确认，避免重复操作。")
        } finally { mutex.unlock() }
    }
    suspend fun following(cursor: String?): Page<Post> = try { withTimeout(22000) {
        account(); val version = http.generation; http.ensureDevice()
        if (relationVersion != version) invalidateFollowing()
        val epoch = relationEpoch
        val data = http.request("/x/polymer/web-dynamic/v1/feed/all",mapOf("type" to "all","platform" to "web","features" to "itemOpusStyle,opusBigCover,ugcDelete") + (cursor?.let { mapOf("offset" to it) } ?: emptyMap()))
        val more=when(val value=data.opt("has_more")) {
            is Boolean -> value
            is Number -> when(value.toDouble()) { 0.0 -> false;1.0 -> true;else -> invalid() }
            else -> invalid()
        }
        if (data.optJSONArray("items") == null && more) invalid()
        val posts = data.rows("items").mapNotNull { Post.parse(it) }.distinctBy { it.id }
        val missing = posts.map { it.author.mid }.distinct().filter { (relationCache[it]?.second ?: 0L) < System.currentTimeMillis() }
        for (batch in missing.chunked(20)) {
            val relations = try { http.request("/x/relation/relations",mapOf("fids" to batch.joinToString(","))) }
                catch (e: BiliFailure) { if (e.code in listOf("404","-400")) JSONObject() else throw e }
            http.check(version)
            if (epoch != relationEpoch) throw CancellationException("关注关系已变化")
            for (group in batch.chunked(4)) coroutineScope {
                group.map { mid -> async { mid to (relations.optJSONObject("$mid")?.let(Relation::parse) ?: relation(mid)) } }.map { it.await() }.forEach { (mid,value) ->
                    http.check(version); if (epoch != relationEpoch) throw CancellationException("关注关系已变化")
                    relationCache[mid]=value to System.currentTimeMillis()+60000
                }
            }
        }
        http.check(version)
        if (epoch != relationEpoch) throw CancellationException("关注关系已变化")
        val next = data.text("offset")
        if (more && (next.isEmpty() || next == cursor)) throw BiliFailure("CURSOR_LOOP","动态分页暂时异常，请下拉刷新。")
        Page(posts.filter { relationCache[it.author.mid]?.first?.following == true },more,next.takeIf { more })
    } } catch (_: TimeoutCancellationException) { throw BiliFailure("FOLLOW_TIMEOUT","关注动态读取超时，请重试。") }
    suspend fun dynamic(id: String): Post {
        if (!Regex("^[1-9][0-9]{0,31}$").matches(id)) invalid()
        return Post.parse(http.request("/x/polymer/web-dynamic/v1/detail",mapOf("id" to id,"platform" to "web","features" to "itemOpusStyle,opusBigCover,ugcDelete")).obj("item")) ?: invalid()
    }
    suspend fun detail(bvid: String): Detail {
        if (!validBvid(bvid)) invalid("BV号不正确。")
        val data = http.request("/x/web-interface/wbi/view",mapOf("bvid" to bvid),wbi=true)
        val video = Video.parse(data)?.takeIf { it.bvid == bvid } ?: invalid()
        val parts = data.rows("pages").map { Part(it.optLong("cid"),it.optInt("page"),it.text("part"),it.optLong("duration"),it.obj("dimension").optInt("width"),it.obj("dimension").optInt("height")) }.filter { it.cid > 0 && it.page > 0 }
        if (parts.isEmpty()) invalid(); val stat = data.obj("stat")
        return Detail(video,parts,data.text("desc"),if (data.optInt("copyright") in listOf(1,3)) 2 else 1,Statistics(stat.optLong("like"),stat.optLong("coin"),stat.optLong("favorite")))
    }
    suspend fun playback(bvid: String, cid: Long, preferred: Int): Playback {
        val data = http.request("/x/player/wbi/playurl",mapOf("bvid" to bvid,"cid" to "$cid","qn" to "$preferred","fnval" to "4048","fnver" to "0","fourk" to "1"),wbi=true,referer="https://www.bilibili.com/video/$bvid")
        return mapPlayback(data,preferred)
    }
    companion object {
        fun mapPlayback(data: JSONObject, preferred: Int): Playback {
            val dash = data.obj("dash")
            val video = dash.rows("video").filter { it.text("codecs").startsWith("avc") }.mapNotNull(Track::parse)
            if (video.isNotEmpty()) {
                val quality = selectQuality(video.map { it.id },preferred)
                val track = video.filter { it.id == quality }.maxBy { it.bandwidth }
                val audio = dash.rows("audio").filter { it.text("codecs").startsWith("mp4a") }.mapNotNull(Track::parse).maxByOrNull { it.bandwidth }
                if (dash.rows("audio").isNotEmpty() && audio == null) invalid("没有可用的AAC音频轨道。")
                val ids = data.optJSONArray("accept_quality"); val descriptions = data.optJSONArray("accept_description")
                val qualities = video.map { it.id }.distinct().sortedDescending().map { id -> val i = (0 until (ids?.length() ?: 0)).firstOrNull { ids!!.optInt(it) == id }; Quality(id,i?.let { descriptions?.optString(it) } ?: "$id") }
                return Playback(quality,qualities,dash.optDouble("duration"),track,audio,null)
            }
            val entries = data.rows("durl"); val direct = entries.singleOrNull()?.text("url")?.let(::mediaUrl) ?: throw BiliFailure("PLAYBACK_UNAVAILABLE","账号暂时没有可用的AVC视频轨道，请检查权限或重试。")
            val actual = data.optInt("quality"); return Playback(actual,listOf(Quality(actual,"当前画质")),data.optDouble("timelength")/1000,null,null,direct)
        }
    }
    suspend fun subtitles(bvid: String, cid: Long): List<Subtitle> = http.request("/x/player/wbi/v2",mapOf("bvid" to bvid,"cid" to "$cid"),wbi=true).obj("subtitle").rows("subtitles").mapNotNull { r -> mediaUrl(r.text("subtitle_url"))?.let { Subtitle(r.optLong("id"),r.text("lan"),r.text("lan_doc"),it) } }
    suspend fun cues(track: Subtitle): List<Cue> {
        val bytes=http.bytes(track.url)
        return withContext(Dispatchers.Default) { JSONObject(String(bytes)).rows("body").map { Cue(it.optDouble("from"),it.optDouble("to"),it.text("content")) } }
    }
    suspend fun comments(oid: String, type: Int = 1, cursor: String? = null): Page<Comment> {
        val data = http.request("/x/v2/reply/wbi/main",mapOf("type" to "$type","oid" to oid,"mode" to "2","pagination_str" to JSONObject().put("offset",cursor ?: "").toString(),"plat" to "1","web_location" to "1315875"),wbi=true)
        val paging = data.obj("cursor"); val end = paging.optBoolean("is_end") || paging.optInt("is_end") == 1
        if (data.optJSONArray("replies") == null && !(end && paging.optInt("all_count") == 0)) invalid(data.obj("control").text("show_text","评论暂时无法读取。"))
        val next = paging.obj("pagination_reply").text("next_offset")
        if (!end && (next.isEmpty() || next == cursor)) invalid("评论分页暂时异常。")
        return Page(data.rows("replies").map { Comment(it.text("rpid_str",it.text("rpid")),User.parse(it.obj("member")),it.obj("content").text("message"),it.optLong("like")) },!end,next.takeUnless { end })
    }
    suspend fun history(cursor: String? = null): Page<History> {
        account(); var query = mapOf("type" to "archive","ps" to "20")
        if (cursor != null) { if (cursor.length > 600) invalid(); val p = JSONObject(String(Base64.decode(cursor,Base64.URL_SAFE or Base64.NO_WRAP))); if (p.optLong("max") <= 0 || p.optLong("view_at") <= 0) invalid(); query += mapOf("max" to p.getLong("max").toString(),"view_at" to p.getLong("view_at").toString(),"business" to p.getString("business")) }
        val data = http.request("/x/web-interface/history/cursor",query)
        if (data.optJSONArray("list") == null || data.optJSONObject("cursor") == null) invalid()
        val items = data.rows("list").mapNotNull { r -> val h = r.obj("history"); if (h.text("business") != "archive") return@mapNotNull null
            val source = JSONObject().put("bvid",h.text("bvid")).put("aid",h.optLong("oid")).put("title",r.text("title")).put("cover",r.text("cover")).put("duration",r.optLong("duration"))
            val v = Video.parse(source,User(r.optLong("author_mid"),r.text("author_name"),secureUrl(r.text("author_face")))) ?: return@mapNotNull null
            History(v,h.optLong("cid"),h.optInt("page",1).coerceAtLeast(1),h.text("part"),r.optLong("progress").coerceAtLeast(0),r.optLong("view_at"),r.optLong("progress") == -1L)
        }.distinctBy { it.video.bvid }
        val position = data.obj("cursor"); val next = if (data.rows("list").isNotEmpty() && position.optLong("max") > 0 && position.optLong("view_at") > 0) Base64.encodeToString(position.toString().toByteArray(),Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING) else null
        return Page(items,next != null && next != cursor,next?.takeIf { it != cursor })
    }
    suspend fun reportHistory(detail: Detail, part: Part, progress: Long) {
        account(); if (part !in detail.parts || detail.video.aid <= 0 || progress < 0) invalid()
        http.request("/x/v2/history/report",form=mapOf("aid" to "${detail.video.aid}","cid" to "${part.cid}","progress" to "${if (part.duration > 0) minOf(progress,part.duration) else progress}","csrf" to http.csrf()))
    }
    suspend fun people(page: Int, frequent: Boolean): Page<User> {
        val uid = account(); val data = http.request("/x/relation/followings",mapOf("vmid" to "$uid","pn" to "$page","ps" to "20","order_type" to if (frequent) "attention" else ""))
        if (!data.has("total") || data.optJSONArray("list") == null && data.optInt("total") > 0) invalid()
        return Page(data.rows("list").map { if (!Relation.parse(it).following) invalid(); User.parse(it) },page*20 < data.optInt("total"))
    }
    private fun folder(r: JSONObject): Folder {
        if (r.optLong("id") <= 0 || !r.has("title") || !r.has("media_count")) invalid()
        return Folder(r.optLong("id"),r.optLong("mid").takeIf { it>0 } ?: r.obj("upper").optLong("mid"),r.text("title"),r.optInt("media_count"),r.optInt("attr") and 1 == 1,r.optInt("fav_state") == 1,r.optInt("max_count",if (r.optInt("attr") and 2 == 0) 50000 else 1000),secureUrl(r.text("cover")))
    }
    suspend fun folders(collected: Boolean, page: Int = 1): Page<Folder> {
        val uid = account(); val data = http.request("/x/v3/fav/folder/${if (collected) "collected" else "created"}/list",mapOf("up_mid" to "$uid","pn" to "$page","ps" to "20","platform" to "web"))
        if (!data.has("count") || data.optJSONArray("list") == null && data.optInt("count") > 0) invalid()
        val items = data.rows("list").map(::folder); if (!collected && items.any { it.mid != uid }) invalid()
        return Page(items,data.optBoolean("has_more",page*20 < data.optInt("count")))
    }
    suspend fun folderVideos(folder: Folder, page: Int): Page<Video> {
        account(); val data = http.request("/x/v3/fav/resource/list",mapOf("media_id" to "${folder.id}","pn" to "$page","ps" to "20","order" to "mtime","type" to "0","platform" to "web"))
        val info = this.folder(data.obj("info")); if (info.id != folder.id || info.mid != folder.mid || !data.has("has_more")) invalid()
        return Page(data.rows("medias").filter { it.optInt("type") == 2 && it.optInt("attr") == 0 }.mapNotNull { r -> r.put("bvid",r.text("bvid",r.text("bv_id"))); Video.parse(r,User.parse(r.obj("upper"))) },data.optBoolean("has_more"))
    }
    suspend fun createFolder(title: String): Folder {
        val uid = account(); if (title.trim().isEmpty() || title.codePointCount(0,title.length) > 20) throw BiliFailure("FOLDER_TITLE","收藏夹名称需要1–20个字。")
        val all = http.request("/x/v3/fav/folder/created/list-all",mapOf("up_mid" to "$uid")); if (all.optInt("count") >= 100) throw BiliFailure("FOLDER_LIMIT","已达到100个收藏夹上限。")
        val data = http.request("/x/v3/fav/folder/add",form=mapOf("title" to title.trim(),"privacy" to "0","csrf" to http.csrf())); return folder(data).also { if (it.mid != uid) invalid() }
    }
    suspend fun videoFolders(detail: Detail): List<Folder> {
        val uid = account(); val data = http.request("/x/v3/fav/folder/created/list-all",mapOf("up_mid" to "$uid","rid" to "${detail.video.aid}","type" to "2"))
        if (!data.has("count") || data.optInt("count") != data.rows("list").size) invalid()
        return data.rows("list").map(::folder).onEach { if (it.mid != uid) invalid() }.sortedByDescending { it.selected }
    }
    suspend fun engagement(bvid: String, deliberateRefresh: Boolean = false): Engagement {
        account(); val data = http.request("/x/web-interface/archive/relation",mapOf("bvid" to bvid))
        if (!data.has("like") || !data.has("coin") || !data.has("favorite") || data.optInt("coin") !in 0..2) invalid("暂时无法确认三连状态。")
        if (deliberateRefresh) uncertain.remove(bvid)
        return Engagement(data.getBoolean("like"),data.getInt("coin"),data.getBoolean("favorite"))
    }
    suspend fun write(detail: Detail, action: VideoWrite): Engagement {
        val bvid = detail.video.bvid; val mutex = videoLocks.getOrPut(bvid) { Mutex() }
        val version = http.generation
        mutex.lock()
        try {
            http.check(version); if (uncertain[bvid] == version) throw BiliFailure("WRITE_UNCERTAIN","请先刷新互动状态，避免重复操作。")
            val before = engagement(bvid); var form = mapOf("bvid" to bvid,"csrf" to http.csrf()); val path: String
            when (action) {
                is VideoWrite.Like -> { if (before.liked == action.selected) return before; path = "/x/web-interface/archive/like"; form += "like" to if (action.selected) "1" else "2" }
                is VideoWrite.Coin -> { if (action.target !in 1..detail.coinLimit) invalid("超过本视频可投的硬币数量。"); if (before.coins >= action.target) return before; path = "/x/web-interface/coin/add"; form += mapOf("multiply" to "${action.target-before.coins}","select_like" to if (action.like) "1" else "0") }
                is VideoWrite.Favorite -> {
                    val folders = videoFolders(detail); if (!folders.map { it.id }.containsAll(action.ids)) invalid("收藏夹已变化，请重新选择。")
                    val add = folders.filter { it.id in action.ids && !it.selected }; val remove = folders.filter { it.id !in action.ids && it.selected }
                    if (add.any { it.count >= it.capacity }) invalid("所选收藏夹已满。")
                    if (add.isEmpty() && remove.isEmpty()) return before
                    path = "/x/v3/fav/resource/deal"; form = mapOf("rid" to "${detail.video.aid}","type" to "2","add_media_ids" to add.joinToString(",") { "${it.id}" },"del_media_ids" to remove.joinToString(",") { "${it.id}" },"csrf" to http.csrf())
                }
                VideoWrite.Triple -> { if (before.complete) return before; path = "/x/web-interface/archive/like/triple" }
            }
            http.ensureDevice(); http.check(version)
            try {
                http.request(path,form=form,referer="https://www.bilibili.com/video/$bvid")
                for (wait in listOf(0L,200L,500L)) {
                    delay(wait); http.check(version); val after = engagement(bvid)
                    val confirmed = when (action) {
                        is VideoWrite.Like -> after.liked == action.selected
                        is VideoWrite.Coin -> after.coins >= action.target && (!action.like || after.liked)
                        is VideoWrite.Favorite -> videoFolders(detail).all { it.selected == (it.id in action.ids) }
                        VideoWrite.Triple -> after.complete
                    }
                    if (confirmed) return after
                }
                throw BiliFailure("WRITE_UNCERTAIN","结果暂未确认，请先刷新状态。")
            } catch (e: Exception) { http.check(version); uncertain[bvid] = version; throw BiliFailure("WRITE_UNCERTAIN","${e.message} 请先刷新互动状态，避免重复操作。") }
        } finally { mutex.unlock() }
    }
}

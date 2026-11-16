package app.bilight.android.core

import android.os.SystemClock
import androidx.compose.runtime.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

private const val WatchLaterPath = "/x/v2/history/toview"
internal const val WatchLaterPageSize = 20
private const val MembershipRefreshMs = 60_000L

internal data class WatchLaterEntry(
    val aid: Long, val video: Video?, val title: String, val cid: Long = 0, val progress: Long = 0,
) {
    val route: Route.Watch?
        get() = video?.let {
            Route.Watch(it.bvid, progress = if (cid > 0) progress.coerceAtLeast(0) else 0, cid = cid.takeIf { id -> id > 0 })
        }
}

internal data class WatchLaterPage(val items: List<WatchLaterEntry>, val total: Int, val more: Boolean)

internal fun parseWatchLaterPage(data: JSONObject, page: Int): WatchLaterPage {
    val total = data.optInt("count", -1)
    if (total < 0 || page < 1) invalid()
    val records = data.optJSONArray("list") ?: run {
        if (total == 0 && data.has("list") && data.isNull("list")) return WatchLaterPage(emptyList(), 0, false)
        invalid()
    }
    val entries = (0 until records.length()).mapNotNull { index ->
        val raw = records.optJSONObject(index) ?: invalid()
        val aid = raw.optLong("aid", Long.MIN_VALUE)
        if (aid in listOf(-1L, 0L)) return@mapNotNull null
        if (aid < 0) invalid()
        val video = Video.parse(raw)?.takeUnless { raw.optInt("state") < 0 }
        WatchLaterEntry(aid, video, raw.text("title").ifBlank { "视频已失效" }, raw.optLong("cid"), raw.optLong("progress"))
    }
    if (entries.isEmpty() && (page.toLong() - 1) * WatchLaterPageSize < total) {
        invalid("B站稍后再看缺少预期的视频，请重试。")
    }
    return WatchLaterPage(entries.distinctBy(WatchLaterEntry::aid), total, page.toLong() * WatchLaterPageSize < total)
}

internal suspend fun BiliRepository.watchLaterPage(page: Int, version: Long): WatchLaterPage {
    http.ensureAccount()
    http.check(version)
    return parseWatchLaterPage(http.request("$WatchLaterPath/web", query = mapOf(
        "pn" to page.toString(), "ps" to WatchLaterPageSize.toString(), "asc" to "0", "viewed" to "0", "need_split" to "1",
    ), expectedGeneration = version), page)
}

internal suspend fun BiliRepository.writeWatchLater(aids: Set<Long>, saved: Boolean, version: Long, bulk: Boolean = false) {
    require(aids.isNotEmpty() && aids.all { it > 0 } && (if (bulk) !saved else aids.size == 1))
    http.ensureAccount()
    http.check(version)
    val (action, id) = when {
        saved -> "add" to ("aid" to aids.single().toString())
        bulk -> "v2/dels" to ("resources" to aids.joinToString(","))
        else -> "del" to ("aid" to aids.single().toString())
    }
    http.request("$WatchLaterPath/$action", form = mapOf(id, "csrf" to http.csrf()), expectedGeneration = version, multipart = bulk)
    http.check(version)
}

/** Membership and list rows are derived from the same in-memory snapshot for the active account. */
internal class WatchLaterModel(private val app: AppModel, private val scope: CoroutineScope) {
    private val repository get() = app.repository
    private val rows = mutableStateListOf<WatchLaterEntry>()
    private val operations = mutableSetOf<Job>()
    private val lock = Mutex()
    private data class Session(val generation: Long, val uid: Long?)
    private var session = Session(-1L, null)
    private var lastCompleteAt = 0L
    private var nextPage by mutableIntStateOf(1)
    private var hasNext by mutableStateOf(true)
    private var stale by mutableStateOf(false)
    private var visibleLimit by mutableIntStateOf(WatchLaterPageSize)
    private var warming: Job? = null
    private var reading: Job? = null
    private var noticeTimeout: Job? = null
    private val pendingVideos = mutableStateMapOf<String, Boolean>()
    private val pendingEntries = mutableStateMapOf<Long, Boolean>()
    var loading by mutableStateOf(false); private set
    var refreshing by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    var toggleMessage by mutableStateOf<String?>(null); private set
    var undo by mutableStateOf<WatchLaterEntry?>(null); private set
    var bulkMessage by mutableStateOf<String?>(null); private set

    val items: List<WatchLaterEntry> get() = rows.take(visibleLimit)
    val loaded: Boolean get() = nextPage > 1
    val more: Boolean get() = hasNext || rows.size > visibleLimit
    val writing: Boolean get() = pendingVideos.isNotEmpty() || pendingEntries.isNotEmpty()

    fun account(version: Long, uid: Long?) {
        val current = Session(version, uid)
        if (current == session) return
        session = current
        lastCompleteAt = 0L
        operations.toList().forEach(Job::cancel)
        operations.clear()
        warming = null
        reading = null
        noticeTimeout?.cancel()
        noticeTimeout = null
        rows.clear()
        nextPage = 1
        hasNext = true
        stale = false
        visibleLimit = WatchLaterPageSize
        loading = false
        refreshing = false
        error = null
        toggleMessage = null
        undo = null
        bulkMessage = null
        pendingEntries.clear()
        pendingVideos.clear()
    }

    private fun active(current: Session) =
        current === session && current.generation == app.http.generation && current.uid != null && current.uid == app.user?.mid

    private fun expired() = !hasNext && SystemClock.elapsedRealtime() - lastCompleteAt >= MembershipRefreshMs

    fun saved(video: Video): Boolean? {
        if (stale || app.user == null) return null
        return if (rows.any { it.aid == video.aid || it.video?.bvid == video.bvid }) true
        else if (hasNext) null else false
    }

    fun pending(video: Video) = pendingVideos.containsKey(video.bvid) || pendingEntries.containsKey(video.aid)
    fun pending(entry: WatchLaterEntry) = pendingEntries.containsKey(entry.aid) || entry.video?.bvid?.let(pendingVideos::containsKey) == true

    private fun launchWork(work: suspend (Session) -> Unit): Job? {
        val current = session
        if (!active(current)) return null
        return scope.launch { work(current) }.also { job ->
            operations += job
            job.invokeOnCompletion { operations -= job }
        }
    }

    private suspend fun fetch(current: Session, reset: Boolean = false) {
        checkActive(current)
        val page = if (reset) 1 else nextPage
        val result = repository.watchLaterPage(page, current.generation)
        checkActive(current)
        val known = if (reset) mutableSetOf() else rows.mapTo(mutableSetOf(), WatchLaterEntry::aid)
        val unique = result.items.filter { known.add(it.aid) }
        if (!result.more && known.size != result.total) {
            stale = true
            invalid("B站稍后再看列表在分页时发生变化，请刷新。")
        }
        if (reset) {
            rows.clear()
            stale = false
        }
        rows.addAll(unique)
        nextPage = page + 1
        hasNext = result.more
        if (!hasNext) lastCompleteAt = SystemClock.elapsedRealtime()
    }

    private fun checkActive(current: Session) {
        if (!active(current)) throw CancellationException("稍后再看账号已变化")
    }

    /** One shared read continues outside a card's composition. Absence is known only after the final page. */
    fun warm() {
        if ((!hasNext && !stale && !expired()) || warming?.isActive == true) return
        warming = launchWork { current ->
            try {
                while (hasNext || stale || expired()) {
                    lock.withLock {
                        val reset = stale || expired()
                        if (hasNext || reset) fetch(current, reset)
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                if (active(current) && !loaded) error = failure.message ?: "稍后再看读取失败。"
            }
        }
    }

    fun load(refresh: Boolean = false, more: Boolean = false, opening: Boolean = false) {
        if (reading?.isActive == true) return
        reading = launchWork { current ->
            loading = true
            refreshing = refresh
            error = null
            if (opening) visibleLimit = WatchLaterPageSize
            if (more && items.size >= visibleLimit) visibleLimit += WatchLaterPageSize
            try {
                lock.withLock {
                    if (refresh || stale) fetch(current, reset = true)
                    while (hasNext && rows.size < visibleLimit) fetch(current)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (active(current)) error = failure.message ?: "稍后再看读取失败。" }
            finally { if (active(current)) { loading = false; refreshing = false } }
        }
    }

    private suspend fun confirmMembership(current: Session) {
        checkActive(current)
        if (stale || expired()) fetch(current, reset = true)
        while (hasNext) fetch(current)
    }

    fun toggle(video: Video) {
        if (!app.requireLogin() || pending(video)) return
        val save = saved(video) != true
        pendingVideos[video.bvid] = true
        if (launchWork { current ->
            try {
                lock.withLock {
                    val aid = video.aid.takeIf { it > 0 } ?: rows.firstOrNull { it.video?.bvid == video.bvid }?.aid
                        ?: repository.detail(video.bvid).video.aid.takeIf { it > 0 } ?: invalid("视频标识不可用。")
                    confirmMembership(current)
                    if (save != rows.any { it.aid == aid }) {
                        write(setOf(aid), save, current)
                        if (save) rows.add(0, WatchLaterEntry(aid, video.copy(aid = aid), video.title))
                        else rows.removeAll { it.aid == aid }
                    }
                    noticeTimeout?.cancel()
                    toggleMessage = if (save) "已添加到稍后再看" else "已从稍后再看移除"
                    noticeTimeout = scope.launch {
                        delay(2_000)
                        toggleMessage = null
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (active(current)) app.error = failure.message ?: "稍后再看操作失败。" }
            finally { if (active(current)) pendingVideos.remove(video.bvid) }
        } == null) pendingVideos.remove(video.bvid)
    }

    fun remove(entries: List<WatchLaterEntry>, bulk: Boolean, onSuccess: () -> Unit = {}) {
        val aids = entries.mapTo(linkedSetOf(), WatchLaterEntry::aid)
        if (aids.isEmpty() || entries.any(::pending) || !app.requireLogin()) return
        aids.forEach { pendingEntries[it] = true }
        if (launchWork { current ->
            try {
                lock.withLock {
                    confirmMembership(current)
                    val removed = rows.filter { it.aid in aids }
                    if (removed.isNotEmpty()) {
                        write(removed.mapTo(linkedSetOf(), WatchLaterEntry::aid), false, current, bulk)
                        if (bulk) bulkMessage = "已移出 ${removed.size} 个视频"
                        else {
                            rows.removeAll { it.aid in aids }
                            undo = removed.single()
                        }
                    }
                    onSuccess()
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (active(current)) app.error = failure.message ?: "无法移出稍后再看。" }
            finally { if (active(current)) aids.forEach(pendingEntries::remove) }
        } == null) aids.forEach(pendingEntries::remove)
    }

    fun restore(entry: WatchLaterEntry) {
        if (pending(entry) || !app.requireLogin()) return
        pendingEntries[entry.aid] = true
        if (launchWork { current ->
            try {
                lock.withLock {
                    confirmMembership(current)
                    if (rows.none { it.aid == entry.aid }) {
                        write(setOf(entry.aid), true, current)
                        rows.add(0, entry)
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (active(current)) app.error = failure.message ?: "无法撤销移除。" }
            finally { if (active(current)) pendingEntries.remove(entry.aid) }
        } == null) pendingEntries.remove(entry.aid)
    }

    private suspend fun write(aids: Set<Long>, saved: Boolean, current: Session, bulk: Boolean = false) {
        try {
            checkActive(current)
            repository.writeWatchLater(aids, saved, current.generation, bulk)
            checkActive(current)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            // Do not repeat a write after an interrupted response. Read the server again before the next attempt.
            if (active(current)) stale = true
            val code = (failure as? BiliFailure)?.code
            if (code != null && code !in setOf("NETWORK", "INVALID_RESPONSE") && (code.toIntOrNull() ?: -1) !in 500..599) throw failure
            throw BiliFailure("WRITE_UNCERTAIN", "${failure.message ?: "B站未返回结果。"} 请先刷新稍后再看，确认操作是否完成。")
        }
        if (!bulk) return
        stale = true
        val confirmed = try {
            withTimeoutOrNull(12_000) { confirmMembership(current); true } ?: false
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { false }
        if (!confirmed) {
            stale = true
            throw BiliFailure("WRITE_UNCERTAIN", "暂时无法确认批量移除结果，请刷新稍后再看。")
        }
        if (rows.any { it.aid in aids }) {
            throw BiliFailure("WRITE_UNCERTAIN", "B站列表仍有部分所选视频，请刷新后重试。")
        }
    }

    fun dismissUndo(entry: WatchLaterEntry) { if (undo === entry) undo = null }
    fun dismissBulk(message: String) { if (bulkMessage == message) bulkMessage = null }
}

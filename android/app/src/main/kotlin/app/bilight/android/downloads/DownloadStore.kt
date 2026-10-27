package app.bilight.android.downloads

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import app.bilight.android.core.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

class DownloadStore(private val context: Context, private val repository: BiliRepository,
    private val client: OkHttpClient = mediaDownloadClient(),
    private val launchService: (() -> Unit)? = null
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var pendingSave: Job? = null
    private val attempts = mutableMapOf<String,Long>()
    private val root = File(context.filesDir, "downloads").apply { mkdirs() }
    private var owner: Long? = null
    private var epoch = 0L
    private var worker: Job? = null
    private var loading: Job? = null
    private var active: Job? = null
    private var activeId: String? = null
    val items = mutableStateListOf<DownloadRecord>()
    var error by mutableStateOf<String?>(null); private set
    var ready by mutableStateOf(false); private set
    var onProgress: ((DownloadRecord?) -> Unit)? = null
    companion object {
    private fun mediaDownloadClient() = OkHttpClient.Builder().connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS).retryOnConnectionFailure(false)
        .addNetworkInterceptor { chain ->
            val url = chain.request().url
            if (!url.isHttps || url.port != 443 || mediaUrl(url.toString()) != url.toString()) throw IOException("下载地址不受信任。")
            chain.proceed(chain.request().newBuilder().removeHeader("Cookie").build())
        }.build()
    }
    fun account(uid: Long?) {
        if (owner == uid && ready) return
        pauseAll(); loading?.cancel(); epoch++; owner = uid; items.clear(); attempts.clear(); error = null; ready = uid == null
        if (uid == null) return
        val ticket = epoch
        loading = scope.launch {
            try {
                pendingSave?.join()
                val restored = withContext(Dispatchers.IO) {
                    SessionVault(context, "downloads-$uid").load()?.let(::decodeDownloads).orEmpty().map { item ->
                        if (item.state.active) item.copy(state = DownloadState.PAUSED) else item
                    }
                }
                if (ticket == epoch) { items.addAll(restored); ready = true; save() }
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) { if (ticket == epoch) { error = "下载列表暂时无法读取，请重试。"; ready = false } }
        }
    }
    private fun directory(uid: Long, id: String): File = File(root, "$uid/$id").apply { mkdirs() }
    fun file(item: DownloadRecord): File? = owner?.takeIf { record(item.id)==item }?.let { File(directory(it, item.id), "video.mp4").takeIf { f -> item.state == DownloadState.COMPLETED && f.length() > 0 } }
    fun record(id: String): DownloadRecord? = items.firstOrNull { it.id == id }
    internal suspend fun awaitSaved() { pendingSave?.join() }
    fun retry() { if (ready) save() else account(owner) }
    private fun save() {
        if (!ready) return
        val uid=owner ?: return; val snapshot=items.toList(); val previous=pendingSave
        pendingSave=scope.launch {
            previous?.join()
            try { withContext(Dispatchers.IO) { SessionVault(context,"downloads-$uid").save(encodeDownloads(snapshot)) }; if (owner==uid && error=="下载列表保存失败，请检查可用空间。") error=null }
            catch (_: Exception) { if (owner==uid) error="下载列表保存失败，请检查可用空间。" }
        }
    }
    private fun replace(id: String, update: (DownloadRecord) -> DownloadRecord) {
        val index = items.indexOfFirst { it.id == id }; if (index < 0) return
        items[index] = update(items[index]); save(); onProgress?.invoke(items[index])
    }
    fun enqueue(detail: Detail, part: Part, quality: Quality) {
        if (!ready || owner == null || owner != repository.http.user?.mid) { error = "请先登录并等待下载列表加载。"; return }
        if (part !in detail.parts) { error = "下载分P不匹配。"; return }
        val existing = items.firstOrNull { it.video.bvid == detail.video.bvid && it.part.cid == part.cid && it.quality == quality.id }
        if (existing != null) { if (existing.state != DownloadState.COMPLETED && !existing.state.active) resume(existing.id); return }
        items.add(0, DownloadRecord(UUID.randomUUID().toString(), detail.video, part, quality.id, quality.label)); save(); startService()
    }
    fun pause(id: String) {
        attempts[id]=(attempts[id] ?: 0)+1
        if (activeId == id) active?.cancel()
        replace(id) { if (it.state.active) it.copy(state = DownloadState.PAUSED) else it }
    }
    fun resume(id: String, restart: Boolean = false) {
        if (!ready || owner == null || owner != repository.http.user?.mid) return
        val item = record(id) ?: return
        if (item.state.active || item.state == DownloadState.COMPLETED) return
        if (restart) {
            val folder = directory(owner!!, id)
            // Delete only files belonging to this exact app-owned download record.
            scope.launch { withContext(Dispatchers.IO) { folder.deleteRecursively() }; replace(id) { it.copy(state = DownloadState.QUEUED, received = 0, total = 0, error = null) }; startService() }
        } else { replace(id) { it.copy(state = DownloadState.QUEUED, error = null) }; startService() }
    }
    fun remove(id: String) {
        val uid = owner ?: return; if (activeId == id) active?.cancel()
        items.removeAll { it.id == id }; save()
        scope.launch { withContext(Dispatchers.IO) { File(root, "$uid/$id").deleteRecursively() } }
    }
    fun pauseAll() {
        worker?.cancel(); worker = null; active?.cancel(); active = null; activeId = null
        for (index in items.indices) if (items[index].state.active) items[index] = items[index].copy(state = DownloadState.PAUSED)
        save()
    }
    private fun startService() {
        try { if (launchService!=null) launchService.invoke() else ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java)) }
        catch (_: Exception) { pauseAll(); error = "系统暂时不允许后台下载，请保持应用在前台后重试。" }
    }
    fun processQueue(finished: () -> Unit) {
        if (worker?.isActive == true) return
        val uid = owner; val ticket = epoch
        if (!ready || uid == null || uid != repository.http.user?.mid) { finished(); return }
        worker = scope.launch {
            try {
                while (isActive && ticket == epoch) {
                    val item = items.firstOrNull { it.state == DownloadState.QUEUED } ?: break
                    activeId = item.id
                    val attempt=(attempts[item.id] ?: 0)+1; attempts[item.id]=attempt
                    active = launch { transfer(uid, ticket, attempt, item) }
                    active!!.join(); activeId = null
                }
            } finally { if (ticket == epoch) { onProgress?.invoke(null); finished() } }
        }
    }
    private suspend fun transfer(uid: Long, ticket: Long, attempt: Long, item: DownloadRecord) {
        fun update(block: (DownloadRecord) -> DownloadRecord) { if (ticket==epoch && attempts[item.id]==attempt) replace(item.id,block) }
        try {
            update { it.copy(state = DownloadState.RESOLVING, error = null) }
            val detail = repository.detail(item.video.bvid)
            if (detail.parts.none { it.cid == item.part.cid && it.page == item.part.page }) invalid("下载分P已变化。")
            val playback = repository.playback(item.video.bvid, item.part.cid, item.quality)
            if (ticket != epoch) throw CancellationException()
            // If permissions changed, the real quality is shown; never modify the user's playback preference.
            val folder = directory(uid, item.id)
            val qualityFile = File(folder, "quality")
            withContext(Dispatchers.IO) {
                if (qualityFile.exists() && qualityFile.readText() != "${playback.quality}") folder.listFiles()?.forEach { it.delete() }
                qualityFile.writeText("${playback.quality}")
            }
            update { it.copy(state = DownloadState.DOWNLOADING, quality = playback.quality, label = playback.qualities.firstOrNull { q -> q.id == playback.quality }?.label ?: it.label) }
            val sources = listOfNotNull((playback.video?.url ?: playback.mp4)?.let { "video" to it }, playback.audio?.url?.let { "audio" to it })
            if (sources.isEmpty()) invalid("没有可下载的视频轨道。")
            val completed = mutableMapOf<String, Long>()
            for ((role, url) in sources) withContext(Dispatchers.IO) {
                downloadTrack(client, url, File(folder, "$role.track")) { bytes, total -> withContext(Dispatchers.Main) {
                    if (ticket != epoch) throw CancellationException()
                    val done = completed.values.sum()
                    update { it.copy(received = done + bytes, total = done + total) }
                } }
                completed[role] = File(folder, "$role.track").length()
            }
            update { it.copy(state = DownloadState.MERGING) }
            withContext(Dispatchers.IO) { muxTracks(File(folder, "video.track"), File(folder, "audio.track").takeIf { playback.audio != null }, File(folder, "video.mp4")) }
            if (ticket != epoch) throw CancellationException()
            update { it.copy(state = DownloadState.COMPLETED, received = completed.values.sum(), total = completed.values.sum(), error = null) }
            withContext(Dispatchers.IO) { folder.listFiles()?.filter { it.name != "video.mp4" }?.forEach { it.delete() } }
        } catch (e: CancellationException) { update { if (it.state.active) it.copy(state = DownloadState.PAUSED) else it }; throw e }
        catch (e: Exception) { update { it.copy(state = DownloadState.FAILED, error = if (e is BiliFailure) e.message else "下载中断，请继续或重新下载。") } }
    }
}

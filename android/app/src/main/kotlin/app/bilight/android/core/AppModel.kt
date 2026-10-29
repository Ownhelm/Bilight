package app.bilight.android.core

import android.app.Application
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import app.bilight.android.playback.PlaybackModel

sealed interface Route {
    data class Watch(val bvid: String, val page: Int = 1, val progress: Long = 0, val downloadId: String? = null, val cid: Long? = null): Route
    data class Creator(val user: User): Route
    data class Catalog(val user: User, val collection: Collection): Route
    data class Dynamic(val post: Post): Route
    data class Favorite(val folder: Folder): Route
    data object History: Route
    data class People(val frequent: Boolean): Route
    data object Favorites: Route
    data object Downloads: Route
}
/** Session-owned reads outlive composables, but never outlive the account that started them. */
class AppModel @JvmOverloads constructor(application: Application, val http: BiliHttp = (application as app.bilight.android.BilightApplication).http, private val playbackFactory: ((AppModel,Route.Watch) -> PlaybackModel)? = null): AndroidViewModel(application) {
    private val services = application as app.bilight.android.BilightApplication
    val repository = if (http===services.http) services.repository else BiliRepository(http)
    val downloads = if (http===services.http) services.downloads else app.bilight.android.downloads.DownloadStore(application,repository)
    private var currentPlayback: PlaybackModel? = null
    private var playbackVersion = -1L
    fun playback(route: Route.Watch): PlaybackModel {
        currentPlayback?.takeIf { it.route==route && playbackVersion==http.generation }?.let { return it }
        currentPlayback?.close(); playbackVersion=http.generation
        return (playbackFactory?.invoke(this,route) ?: PlaybackModel(this,route)).also { currentPlayback=it }
    }
    fun releasePlayback(value: PlaybackModel) { if (currentPlayback===value) { value.close(); currentPlayback=null } }
    override fun onCleared() { currentPlayback?.close(); super.onCleared() }
    var user by mutableStateOf<User?>(null); private set
    var restoring by mutableStateOf(true); private set
    var error by mutableStateOf<String?>(null)
    var showLogin by mutableStateOf(false)
    var showAccount by mutableStateOf(false)
    var sessionRevision by mutableLongStateOf(0); private set
    private var accountVersion = -1L
    var tab by mutableIntStateOf(0)
    val routes = mutableStateListOf<Route>()
    val following = mutableStateListOf<Post>()
    val expandedPosts = mutableStateMapOf<String,Boolean>()
    var feedLoaded by mutableStateOf(false); private set
    var feedBusy by mutableStateOf(false); private set
    var feedMore by mutableStateOf(false); private set
    var feedError by mutableStateOf<String?>(null); private set
    var feedIndex = 0
    var feedOffset = 0
    var feedAnchor: String? = null
    var feedEntryRevision by mutableLongStateOf(0); private set
    private var handledFeedEntry = 0L
    private var feedRequest = 0L
    var feedRefreshing by mutableStateOf(false); private set
    private var feedCursor: String? = null
    private var feedJob: Job? = null
    val relations = mutableStateMapOf<Long,Relation>()
    val followBusy = mutableStateMapOf<Long,Boolean>()
    private val accountJobs = mutableListOf<Job>()
    var historyError by mutableStateOf<String?>(null); private set
    private val reporter = HistoryReporter(viewModelScope, { report -> http.check(report.version); repository.reportHistory(report.detail,report.part,report.progress); http.check(report.version) }, { historyError=it })
    fun retryHistory() { if (user != null) reporter.retry() }
    fun report(detail: Detail,part: Part,progress: Long,version: Long) { if (user != null && version == http.generation) reporter.submit(HistoryReport(detail,part,progress,version)) }
    var keyword by mutableStateOf("")
    var searchUsers by mutableStateOf(false)
    val searchItems = mutableStateListOf<Any>()
    var searchBusy by mutableStateOf(false)
    var searched by mutableStateOf(false)
    var searchMore by mutableStateOf(false)
    var searchError by mutableStateOf<String?>(null)
    private var searchPage = 0
    var searchRevision by mutableIntStateOf(0); private set
    var searchIndex = 0
    var searchOffset = 0
    private var searchJob: Job? = null
    fun search(reset: Boolean = true) {
        val query = keyword.trim(); if (query.isEmpty()) return
        bvidFrom(query)?.let { open(Route.Watch(it)); return }
        if (!reset && searchBusy) return
        if (reset) { searchJob?.cancel(); searchPage = 0; searchIndex=0; searchOffset=0; searchRevision++; searchItems.clear() }
        val next = searchPage+1; val users = searchUsers; val version = http.generation
        searchBusy = true; searchError = null; searched = true
        searchJob = viewModelScope.launch {
            try { val page = repository.search(query,users,next); http.check(version); searchItems.addAll(page.items); searchPage=next; searchMore=page.more }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { searchError=e.message }
            finally { searchBusy=false }
        }
    }
    init {
        val version=http.generation
        viewModelScope.launch {
            try { val value=http.restore(); http.check(version); update(value,initialRestore=true) }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (version==http.generation) error=e.message }
            finally { restoring=false }
        }
    }
    fun update(value: User?, initialRestore: Boolean = false) {
        // Loading the existing session must not close a public page already opened during startup.
        val keepNavigation=initialRestore && accountVersion == -1L && user==null
        if (!keepNavigation && (value?.mid != user?.mid || accountVersion!=http.generation)) {
            sessionRevision++; searchRevision++
            currentPlayback?.close(); currentPlayback=null
            downloads.pauseAll()
            feedRequest++; feedJob?.cancel(); accountJobs.forEach(Job::cancel); accountJobs.clear()
            following.clear(); expandedPosts.clear(); feedLoaded = false; feedMore = false; feedBusy = false; feedRefreshing=false; feedError = null
            feedCursor = null; feedIndex = 0; feedOffset = 0; feedAnchor=null; relations.clear(); followBusy.clear(); routes.clear()
            repository.invalidateFollowing()
            searchJob?.cancel(); searchItems.clear(); searched=false; searchBusy=false; searchIndex=0; searchOffset=0
        }
        user = value
        accountVersion=http.generation
        reporter.account(http.generation)
        downloads.account(value?.mid)
    }
    fun open(route: Route) { showAccount = false; routes.add(route) }
    fun back() { if (routes.isNotEmpty()) routes.removeAt(routes.lastIndex) }
    fun requireLogin(): Boolean { if (user != null) return true; showLogin = true; return false }
    fun login(header: String, complete: (Boolean,String?) -> Unit): Job =
        viewModelScope.launch { try { update(http.acceptLogin(header)); error = null; showLogin = false; complete(true,null) } catch (e: CancellationException) { throw e } catch (e: Exception) { complete(false,e.message) } finally { if (accountVersion!=http.generation) update(http.user) } }
    fun logout() { viewModelScope.launch { http.logout(); update(null); showAccount = false } }
    fun loadFeed(refresh: Boolean = false) {
        if (!requireLogin() || (feedBusy && (!refresh || feedRefreshing)) || (!refresh && feedLoaded && !feedMore)) return
        val token=++feedRequest
        feedJob?.cancel(); feedRefreshing=refresh || !feedLoaded
        val resetting=feedRefreshing
        val version = http.generation
        feedBusy = true; feedError = null
        if (refresh) repository.invalidateFollowing()
        feedJob = viewModelScope.launch {
            val began=android.os.SystemClock.elapsedRealtime()
            try {
                val result = repository.following(if (refresh || !feedLoaded) null else feedCursor)
                http.check(version); if (feedRequest!=token) return@launch
                if (refresh || !feedLoaded) { following.clear(); feedIndex = 0; feedOffset = 0; feedAnchor=null }
                val known = following.map { it.id }.toSet(); following.addAll(result.items.filter { it.id !in known })
                feedLoaded = true; feedMore = result.more; feedCursor = result.cursor
            } catch (e: CancellationException) { throw e } catch (e: Exception) { if (version == http.generation && feedRequest==token) feedError = e.message ?: "关注动态读取失败，请重试。" }
            finally {
                // Keep fast refreshes visible without issuing another network request.
                if (resetting && isActive) delay((400-(android.os.SystemClock.elapsedRealtime()-began)).coerceAtLeast(0))
                if (version == http.generation && feedRequest==token) { feedBusy = false; feedRefreshing=false }
            }
        }
    }
    fun enterFollowing() {
        tab=1; feedIndex=0; feedOffset=0; feedAnchor=null; feedEntryRevision++
        if (user!=null) loadFeed(true)
    }
    fun consumeFeedEntry(): Boolean {
        if (handledFeedEntry==feedEntryRevision) return false
        handledFeedEntry=feedEntryRevision
        return true
    }
    fun readRelation(mid: Long) {
        if (user == null || user?.mid == mid || relations.containsKey(mid)) return
        val version = http.generation
        accountJobs += viewModelScope.launch { try { val relation = repository.relation(mid); http.check(version); relations[mid] = relation } catch (_: Exception) { /* A visible fresh check runs before the actual write. */ } }
    }
    fun follow(mid: Long) {
        if (!requireLogin() || followBusy[mid] == true) return
        val desired=relations[mid]?.following!=true
        followBusy[mid] = true; val version = http.generation
        accountJobs += viewModelScope.launch {
            try {
                val after = repository.follow(mid,desired); http.check(version); relations[mid] = after
                if (!after.following) {
                    following.removeAll { it.author.mid == mid }
                    val anchor=following.indexOfFirst { it.id==feedAnchor }
                    if (anchor>=0) feedIndex=anchor else { feedIndex=feedIndex.coerceAtMost((following.size-1).coerceAtLeast(0)); feedOffset=0; feedAnchor=following.getOrNull(feedIndex)?.id }
                }
            } catch (e: Exception) { if (version == http.generation) error = e.message }
            finally { if (version == http.generation) followBusy.remove(mid) }
        }
    }
}

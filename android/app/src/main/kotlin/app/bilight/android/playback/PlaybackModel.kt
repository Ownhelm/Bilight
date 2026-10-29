package app.bilight.android.playback

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.*
import androidx.media3.common.*
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.dash.manifest.DashManifest
import androidx.media3.exoplayer.dash.manifest.DashManifestParser
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import app.bilight.android.core.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import java.io.IOException
import java.util.concurrent.TimeUnit

class PlaybackSettings(context: Context) {
    private val store = context.getSharedPreferences("playback-preferences",Context.MODE_PRIVATE)
    var quality: Int get() = store.getInt("quality",127); set(value) { store.edit().putInt("quality",value).apply() }
    var danmaku: Boolean get() = store.getBoolean("danmaku",false); set(value) { store.edit().putBoolean("danmaku",value).apply() }
    var font: Int get() = store.getInt("danmakuFont",20); set(value) { store.edit().putInt("danmakuFont",value).apply() }
    var area: Float get() = store.getFloat("danmakuArea",1f); set(value) { store.edit().putFloat("danmakuArea",value).apply() }
    var opacity: Float get() = store.getFloat("danmakuOpacity",1f); set(value) { store.edit().putFloat("danmakuOpacity",value).apply() }
}
private fun playbackMediaClient() = OkHttpClient.Builder().connectTimeout(10,TimeUnit.SECONDS).readTimeout(20,TimeUnit.SECONDS).followRedirects(true).retryOnConnectionFailure(false).addNetworkInterceptor { chain ->
    val target=chain.request().url
    if (!target.isHttps || target.port!=443 || mediaUrl(target.toString())!=target.toString()) throw IOException("媒体地址不受信任")
    val response=chain.proceed(chain.request().newBuilder().removeHeader("Cookie").header("Referer","https://www.bilibili.com/").header("User-Agent",BiliHttp.USER_AGENT).build())
    val type=response.header("Content-Type").orEmpty().lowercase()
    if (response.isSuccessful && type.isNotEmpty() && !type.startsWith("video/") && !type.startsWith("audio/") && !type.startsWith("application/octet-stream")) { response.close(); throw IOException("媒体响应类型不正确") }
    response
}.build()
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlaybackModel(private val app: AppModel,val route: Route.Watch, private val mediaClient: OkHttpClient = playbackMediaClient()) {
    val offline get() = route.downloadId != null
    val aspectRatio: Float get() {
        val dimensions=playback?.video?.takeIf { it.width>0 && it.height>0 }?.let { it.width to it.height }
            ?: part?.takeIf { it.width>0 && it.height>0 }?.let { it.width to it.height }
            ?: detail?.video?.takeIf { it.width>0 && it.height>0 }?.let { it.width to it.height }
        return dimensions?.let { it.first.toFloat()/it.second } ?: 16f/9
    }
    private val context = app.getApplication<android.app.Application>()
    private val scope = CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private val preferences = PlaybackSettings(context)
    val player = ExoPlayer.Builder(context).setSeekBackIncrementMs(10000).setSeekForwardIncrementMs(10000).setLoadControl(DefaultLoadControl.Builder().setBufferDurationsMs(12000,35000,1000,1500).setPrioritizeTimeOverSizeThresholds(true).build()).build().apply {
        setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),true)
        repeatMode=Player.REPEAT_MODE_OFF
        setHandleAudioBecomingNoisy(true)
        setWakeMode(C.WAKE_MODE_NETWORK)
    }
    var detail by mutableStateOf<Detail?>(null); private set
    var part by mutableStateOf<Part?>(null); private set
    var playback by mutableStateOf<Playback?>(null); private set
    var preparing by mutableStateOf(true); private set
    var waiting by mutableStateOf(false); private set
    var hasFrame by mutableStateOf(false); private set
    var playing by mutableStateOf(false); private set
    val buffering get() = preparing || waiting || (!hasFrame && playback!=null && player.playWhenReady && player.playbackState!=Player.STATE_ENDED && error==null)
    var position by mutableLongStateOf(route.progress*1000); private set
    var duration by mutableLongStateOf(0); private set
    var speed by mutableFloatStateOf(1f); private set
    var error by mutableStateOf<String?>(null); private set
    var supportError by mutableStateOf<String?>(null); private set
    var subtitleError by mutableStateOf<String?>(null); private set
    var tracks by mutableStateOf(emptyList<Subtitle>()); private set
    var subtitle by mutableStateOf<Subtitle?>(null); private set
    var cues by mutableStateOf(emptyList<Cue>()); private set
    var subtitleText by mutableStateOf(""); private set
    var danmaku by mutableStateOf(preferences.danmaku); private set
    var danmakuFont by mutableIntStateOf(preferences.font); private set
    var danmakuArea by mutableFloatStateOf(preferences.area); private set
    var danmakuOpacity by mutableFloatStateOf(preferences.opacity); private set
    var danmakuItems by mutableStateOf(emptyList<Danmaku>()); private set
    var danmakuError by mutableStateOf<String?>(null); private set
    var engagement by mutableStateOf<Engagement?>(null); private set
    var actionBusy by mutableStateOf(false); private set
    var fullscreen by mutableStateOf(false)
    var portraitFullscreen by mutableStateOf(false)
    var seekHint by mutableStateOf<String?>(null); private set
    var settings by mutableStateOf(false)
    var controlsVisible by mutableStateOf(true)
    var informationIndex = 0
    var informationOffset = 0
    val comments = mutableStateListOf<Comment>()
    var commentsBusy by mutableStateOf(false); private set
    var commentsMore by mutableStateOf(true); private set
    var commentsError by mutableStateOf<String?>(null); private set
    var commentsExpanded by mutableStateOf(true)
    private var commentCursor: String? = null
    private var prepareJob: Job? = null
    private var subtitleJob: Job? = null
    private var danmakuJob: Job? = null
    private var bufferJob: Job? = null
    private var engagementRead: Job? = null
    private var refreshSupport = false
    private var temporarySpeed: Float? = null
    private val version=app.http.generation
    private val visibility=PlaybackVisibility()
    private var lastPosition=0L
    private var advanced=false
    private var lastReport=0L
    private var closed=false
    private var refreshedMedia=false
    init {
        player.addListener(object: Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) { playing=isPlaying; if (!isPlaying) flushHistory() }
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean,reason: Int) { updateBuffering() }
            override fun onPlaybackStateChanged(state: Int) {
                updateBuffering()
                if (state==Player.STATE_ENDED) { flushHistory(); controlsVisible=true }
            }
            override fun onRenderedFirstFrame() { hasFrame=true; preparing=false; waiting=false }
            override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo,newPosition: Player.PositionInfo,reason: Int) { lastPosition=newPosition.positionMs }
            override fun onPlayerError(failure: PlaybackException) {
                val causes=generateSequence<Throwable>(failure) { it.cause }.take(8).toList()
                val status=causes.filterIsInstance<HttpDataSource.InvalidResponseCodeException>().firstOrNull()?.responseCode
                if (status==403 && !offline && !refreshedMedia && part!=null) {
                    refreshedMedia=true
                    val selected=part!!; val progress=player.currentPosition; val intent=visibility.currentIntent(player.playWhenReady)
                    val quality=playback?.quality ?: preferences.quality
                    prepareJob?.cancel(); preparing=true; waiting=false; hasFrame=false; error=null
                    prepareJob=scope.launch {
                        try { prepare(selected,progress,intent,loadSupport=false,preferredQuality=quality) }
                        catch (e: CancellationException) { throw e }
                        catch (e: Exception) { error=e.message; preparing=false; controlsVisible=true }
                    }
                    return
                }
                error=when {
                    status in listOf(401,403) -> "媒体访问被拒绝或链接已过期，请重新加载（HTTP $status）。"
                    status in listOf(412,429) -> "B站暂时限制了媒体请求，请稍后重试（HTTP $status）。"
                    status!=null -> "媒体加载失败（HTTP $status），请重新加载。"
                    causes.any { it is javax.net.ssl.SSLException } -> "媒体安全连接验证失败，请检查网络和系统时间。"
                    failure.errorCode in 4000..4999 -> "当前设备无法解码此画质，请在设置中选择较低画质（${failure.errorCode}）。"
                    failure.errorCode==PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> "视频连接超时，请重新加载。"
                    else -> "视频加载失败（${failure.errorCode}），请重新加载。"
                }; preparing=false; waiting=false; controlsVisible=true
            }
        })
        load()
        scope.launch { while (isActive) {
            delay(if (visibility.background) 1000 else 250)
            position=player.currentPosition.coerceAtLeast(0); duration=player.duration.takeIf { it>0 } ?: ((playback?.duration ?: 0.0)*1000).toLong()
            if (player.isPlaying && position-lastPosition in 1..(1500*maxOf(1f,speed)).toLong()) advanced=true
            lastPosition=position
            if (advanced && android.os.SystemClock.elapsedRealtime()-lastReport>=15000) flushHistory()
            val seconds=position/1000.0; subtitleText=cues.firstOrNull { seconds>=it.from && seconds<it.to }?.text.orEmpty()
        } }
    }
    private fun updateBuffering() {
        bufferJob?.cancel()
        if (player.playbackState==Player.STATE_BUFFERING && player.playWhenReady) bufferJob=scope.launch {
            delay(200); if (player.playbackState==Player.STATE_BUFFERING && player.playWhenReady) waiting=true
        } else waiting=false
    }
    private fun load() {
        prepareJob?.cancel(); preparing=true; error=null
        prepareJob=scope.launch { try {
            if (offline) {
                val item=app.downloads.record(route.downloadId!!) ?: invalid("离线视频不属于当前账号。")
                val file=app.downloads.file(item) ?: invalid("离线文件不存在，请重新下载。")
                detail=Detail(item.video,listOf(item.part),"",2,Statistics(0,0,0)); part=item.part
                playback=Playback(item.quality,listOf(Quality(item.quality,item.label)),item.part.duration.toDouble(),null,null,null)
                player.setMediaItem(mediaItem(Uri.fromFile(file),item.part),route.progress*1000); player.prepare(); player.playWhenReady=visibility.prepared(true); preparing=false
                return@launch
            }
            val value=app.repository.detail(route.bvid); app.http.check(version); detail=value
            val selected=if (route.cid!=null) value.parts.firstOrNull { it.cid==route.cid } else value.parts.firstOrNull { it.page==route.page }
            if (selected==null) invalid("该分P已失效，请选择其他分P。")
            part=selected; prepare(selected,route.progress*1000,true)
            loadComments(); readEngagement()
        } catch (e: CancellationException) { throw e } catch (e: Exception) { error=e.message; preparing=false } }
    }
    private suspend fun prepare(selected: Part,progress: Long,autoplay: Boolean,loadSupport: Boolean = true,preserveCurrent: Boolean = false,preferredQuality: Int = preferences.quality) {
        val result=app.repository.playback(route.bvid,selected.cid,preferredQuality); app.http.check(version)
        playback=result
        val sourceFactory=DefaultDataSource.Factory(context,OkHttpDataSource.Factory(mediaClient))
        val item=mediaItem(Uri.parse(result.mp4 ?: "https://www.bilibili.com/bilight-manifest.mpd"),selected)
        val source=if (result.mp4!=null) ProgressiveMediaSource.Factory(sourceFactory).createMediaSource(item) else {
            // Sideload the static MPD: Media3's CMCD URI handling rejects opaque data: URIs.
            DashMediaSource.Factory(sourceFactory).createMediaSource(parsedDashManifest(result),item)
        }
        val target=if (preserveCurrent) player.currentPosition else progress
        val intent=if (preserveCurrent) visibility.currentIntent(player.playWhenReady) else autoplay
        player.setMediaSource(source,target); player.prepare(); player.playWhenReady=visibility.prepared(intent)
        // The user-selected preference is intentionally not overwritten by the returned lower quality.
        preparing=false
        if (loadSupport) { loadSubtitles(selected); loadDanmaku() }
    }
    private fun mediaItem(uri: Uri,selected: Part): MediaItem {
        val video=detail?.video
        val metadata=MediaMetadata.Builder().setTitle(video?.title).setArtist(video?.owner?.name)
            .setAlbumTitle("P${selected.page} · ${selected.title}").setMediaType(MediaMetadata.MEDIA_TYPE_VIDEO)
            .setIsPlayable(true).setIsBrowsable(false).setArtworkUri(video?.cover?.let(Uri::parse)).build()
        return MediaItem.Builder().setMediaId("${route.bvid}:${selected.cid}").setUri(uri).setMediaMetadata(metadata).build()
    }
    fun retry() { if (offline || detail==null || part==null) load() else selectPart(part ?: return,position) }
    fun selectPart(selected: Part,progress: Long = 0) {
        endTemporarySpeed()
        if (offline) return
        flushHistory(); player.pause(); prepareJob?.cancel(); subtitleJob?.cancel(); danmakuJob?.cancel()
        part=selected; playback=null; tracks=emptyList(); subtitle=null; subtitleError=null; subtitleText=""; cues=emptyList(); danmakuItems=emptyList(); hasFrame=false; preparing=true; error=null; advanced=false; lastPosition=player.currentPosition; refreshedMedia=false
        prepareJob=scope.launch { try { prepare(selected,progress,true) } catch (e: CancellationException) { throw e } catch (e: Exception) { error=e.message; preparing=false } }
    }
    fun chooseQuality(id: Int) {
        endTemporarySpeed()
        if (offline) return
        if (playback?.qualities?.none { it.id==id } != false) return
        preferences.quality=id
        // Selecting the current quality must still replace an in-flight switch to another quality.
        if (playback?.quality==id && error==null && prepareJob?.isActive!=true) return
        val selected=part ?: return; val progress=player.currentPosition; val autoplay=player.playWhenReady
        prepareJob?.cancel(); error=null; preparing=true; refreshedMedia=false
        prepareJob=scope.launch { try { prepare(selected,progress,autoplay,loadSupport=false,preserveCurrent=true) } catch (e: CancellationException) { throw e } catch (e: Exception) { error=e.message; preparing=false } }
    }
    fun speed(value: Float) { speed=value; if (temporarySpeed!=null) temporarySpeed=value else player.setPlaybackSpeed(value) }
    fun beginTemporarySpeed() { if (temporarySpeed==null && player.playWhenReady && playback!=null) { temporarySpeed=speed; player.setPlaybackSpeed(2f) } }
    fun endTemporarySpeed() { val value=temporarySpeed ?: return; temporarySpeed=null; player.setPlaybackSpeed(value) }
    fun toggle() {
        if (error!=null) { retry(); return }; if (playback==null) return
        // Ended players can retain playWhenReady=true; replay must explicitly request playback.
        if (player.playbackState==Player.STATE_ENDED) { player.seekTo(0); player.playWhenReady=true }
        else player.playWhenReady=!player.playWhenReady
        controlsVisible=true
        if (!player.playWhenReady) { waiting=false; bufferJob?.cancel(); flushHistory() }
    }
    fun seek(milliseconds: Long) {
        // The native timeline can be ready before the UI timer publishes its first duration.
        duration=(player.duration.takeIf { it>0 } ?: duration).coerceAtLeast(0)
        player.seekTo(milliseconds.coerceIn(0,duration)); lastPosition=player.currentPosition; position=lastPosition
    }
    fun doubleTap(fraction: Float) {
        if (playback==null) return
        when (tapZone(fraction)) { TapZone.TOGGLE -> toggle(); TapZone.BACKWARD -> { seek(position-10000); seekHint="后退10秒 · ${clock(position/1000)}" }; TapZone.FORWARD -> { seek(position+10000); seekHint="前进10秒 · ${clock(position/1000)}" } }
        scope.launch { delay(700); seekHint=null }
    }
    fun enableBackgroundPlayback() { PlaybackService.attach(context,this) }
    fun background() { endTemporarySpeed(); visibility.leave(player.playWhenReady); flushHistory() }
    fun foreground() { val resume=visibility.enter(); if (!closed && resume && error==null) player.playWhenReady=true }
    private fun flushHistory() {
        if (!advanced) return
        val d=detail ?: return; val p=part ?: return
        app.report(d,p,player.currentPosition.coerceAtLeast(0)/1000,version); advanced=false; lastReport=android.os.SystemClock.elapsedRealtime()
    }
    fun loadComments() {
        val d=detail ?: return; if (commentsBusy || !commentsMore) return
        commentsBusy=true; commentsError=null
        scope.launch { try { val page=app.repository.comments("${d.video.aid}",cursor=commentCursor); app.http.check(version); val known=comments.map { it.id }.toSet(); comments.addAll(page.items.filter { it.id !in known }); commentsMore=page.more; commentCursor=page.cursor } catch (e: CancellationException) { throw e } catch (e: Exception) { commentsError=e.message } finally { commentsBusy=false } }
    }
    fun readEngagement() { if (app.user==null || actionBusy) return; engagementRead?.cancel(); engagementRead=scope.launch { try { val value=app.repository.engagement(route.bvid,true); app.http.check(version); if (!actionBusy) { engagement=value; refreshSupport=false; supportError=null } } catch (e: CancellationException) { throw e } catch (e: Exception) { supportError=e.message } } }
    fun write(action: VideoWrite) {
        if (!app.requireLogin() || actionBusy) return
        val d=detail ?: return; actionBusy=true; engagementRead?.cancel()
        val before=engagement; val pending=before ?: Engagement(false,0,false)
        val silent=action !is VideoWrite.Favorite
        engagement=when (action) {
            is VideoWrite.Like -> pending.copy(liked=action.selected)
            is VideoWrite.Coin -> pending.copy(coins=maxOf(pending.coins,action.target),liked=pending.liked || action.like)
            VideoWrite.Triple -> pending.copy(liked=true,coins=maxOf(1,pending.coins),favorite=true)
            is VideoWrite.Favorite -> before
        }
        supportError=null
        scope.launch { try {
            if (refreshSupport) app.repository.engagement(route.bvid,true)
            app.http.check(version)
            val value=app.repository.write(d,action); app.http.check(version); engagement=value; refreshSupport=false
            try { val fresh=app.repository.detail(route.bvid); app.http.check(version); detail=fresh }
            catch (e: CancellationException) { throw e } catch (e: Exception) { if (!silent) supportError="互动已更新，计数暂时无法刷新：${e.message}" }
        } catch (e: CancellationException) { if (!closed && app.http.generation==version) engagement=before; throw e }
        catch (e: Exception) { if (!closed && app.http.generation==version) { engagement=before; refreshSupport=true; supportError=if (silent) null else e.message } }
        finally { actionBusy=false } }
    }
    private fun loadSubtitles(selected: Part) {
        subtitleJob?.cancel(); subtitleError=null; cues=emptyList(); subtitleText=""; subtitle=null
        subtitleJob=scope.launch { try {
            val result=app.repository.subtitles(route.bvid,selected.cid); tracks=result
            val best=result.firstOrNull { it.language.startsWith("zh") || it.language.startsWith("ai-zh") } ?: result.firstOrNull()
            if (best!=null) { subtitle=best; cues=app.repository.cues(best) }
        } catch (e: CancellationException) { throw e } catch (e: Exception) { subtitleError=e.message } }
    }
    fun subtitle(track: Subtitle?) {
        if (track!=null && track !in tracks) return
        subtitleJob?.cancel(); subtitle=track; cues=emptyList(); subtitleText=""; subtitleError=null
        if (track!=null) subtitleJob=scope.launch { try { cues=app.repository.cues(track) } catch (e: CancellationException) { throw e } catch (e: Exception) { subtitleError=e.message } }
    }
    fun danmaku(value: Boolean) { danmaku=value; preferences.danmaku=value; loadDanmaku() }
    fun font(value: Int) { danmakuFont=value; preferences.font=value }
    fun area(value: Float) { danmakuArea=value; preferences.area=value }
    fun opacity(value: Float) { danmakuOpacity=value; preferences.opacity=value }
    private fun loadDanmaku() {
        danmakuJob?.cancel(); danmakuItems=emptyList(); danmakuError=null
        val cid=part?.cid ?: return; if (!danmaku) return
        danmakuJob=scope.launch { try { val bytes=app.http.bytes("https://api.bilibili.com/x/v1/dm/list.so?oid=$cid"); val values=withContext(Dispatchers.Default) { Danmaku.parse(bytes) }; app.http.check(version); danmakuItems=values } catch (e: CancellationException) { throw e } catch (e: Exception) { danmakuError=e.message } }
    }
    fun close() { if (closed) return; endTemporarySpeed(); flushHistory(); closed=true; PlaybackService.detach(context,this); scope.cancel(); player.release(); mediaClient.dispatcher.cancelAll() }
}

private fun xml(value: String): String = value.replace("&","&amp;").replace("\"","&quot;").replace("<","&lt;").replace(">","&gt;")
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
fun parsedDashManifest(playback: Playback): DashManifest = DashManifestParser().parse(
    Uri.parse("https://www.bilibili.com/bilight-manifest.mpd"),
    dashManifest(playback).byteInputStream()
)
fun dashManifest(playback: Playback): String {
    fun adaptation(track: Track,video: Boolean): String = """<AdaptationSet mimeType="${if (video) "video/mp4" else "audio/mp4"}" contentType="${if (video) "video" else "audio"}" segmentAlignment="true"><Representation id="${track.id}" codecs="${xml(track.codecs)}" bandwidth="${track.bandwidth}" ${if (video) "width=\"${track.width}\" height=\"${track.height}\"" else "audioSamplingRate=\"48000\""}><BaseURL>${xml(track.url)}</BaseURL><SegmentBase indexRange="${track.indexRange}"><Initialization range="${track.initialization}"/></SegmentBase></Representation></AdaptationSet>"""
    return """<?xml version="1.0" encoding="UTF-8"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" minBufferTime="PT1.5S" mediaPresentationDuration="PT${playback.duration}S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period duration="PT${playback.duration}S">${playback.video?.let { adaptation(it,true) }.orEmpty()}${playback.audio?.let { adaptation(it,false) }.orEmpty()}</Period></MPD>"""
}

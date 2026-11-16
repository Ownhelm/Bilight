@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package app.bilight.android.ui

import android.content.pm.ActivityInfo
import android.media.AudioManager
import android.provider.Settings
import android.view.OrientationEventListener
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.LinearEasing
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.LayoutDirection

import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.ui.PlayerView
import app.bilight.android.core.*
import app.bilight.android.playback.*
import kotlinx.coroutines.*
import java.util.Locale
import kotlin.math.min
import kotlin.math.roundToInt

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable fun VideoScreen(app: AppModel,route: Route.Watch) {
    val model=remember(route,app.http.generation) { app.playback(route) }
    val commentComposer=remember(model) { VideoCommentComposerState() }
    LaunchedEffect(model) { model.enableBackgroundPlayback() }
    val activity=checkNotNull(LocalActivity.current)
    val scope=rememberCoroutineScope()
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    val hostView=LocalView.current
    DisposableEffect(hostView,lifecycle,model.player) {
        val screenAwake=PlaybackScreenAwake(hostView,model.player,lifecycle)
        onDispose { screenAwake.close() }
    }
    val landscape=LocalConfiguration.current.orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE
    val currentLandscape by rememberUpdatedState(landscape)
    var active by remember { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    var suppressRotation by remember { mutableStateOf(false) }
    var seenLandscape by remember { mutableStateOf(false) }
    var exiting by remember { mutableStateOf(false) }
    var keepFullscreenOnReturn by remember(model) { mutableStateOf(model.fullscreen) }
    val rotation = remember(model,scope) { PlaybackRotation(scope) }
    fun orientation(value: Int) { if (activity.requestedOrientation!=value) activity.requestedOrientation=value }
    fun fullscreenOrientation() = if (model.portraitFullscreen) ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR else ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    fun exit() {
        if (exiting) return
        exiting=currentLandscape && model.fullscreen
        keepFullscreenOnReturn=false; model.fullscreen=false; model.portraitFullscreen=false
        seenLandscape=false; suppressRotation=rotation.settled!=PlaybackPosture.UPRIGHT
        orientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
    }
    fun toggleFullscreen() {
        if (exiting) return
        if (model.fullscreen) { exit(); return }
        suppressRotation=false; keepFullscreenOnReturn=false
        model.portraitFullscreen=model.aspectRatio<1f
        model.fullscreen=true; model.controlsVisible=true
        seenLandscape=rotation.settled?.let { it!=PlaybackPosture.UPRIGHT }==true
        orientation(fullscreenOrientation())
    }
    // Change layout only with the target window orientation. The embedded player never stretches first.
    val presentedFullscreen=fullscreenPresentation(model.fullscreen,model.portraitFullscreen,landscape,keepFullscreenOnReturn,exiting)
    BackHandler(model.fullscreen || exiting) { exit() }
    LaunchedEffect(landscape) { if (!landscape) exiting=false }
    DisposableEffect(model) {
        orientation(if (model.fullscreen) fullscreenOrientation() else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
        onDispose {
            if (!activity.isChangingConfigurations) { app.releasePlayback(model); orientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT) }
        }
    }
    DisposableEffect(lifecycle,model) {
        var listener: OrientationEventListener? = null
        fun stopListening() {
            listener?.disable()
            listener=null
            rotation.reset()
        }
        fun confirmedPosture(posture: PlaybackPosture) {
            if (!active) return
            if (posture==PlaybackPosture.UPRIGHT) {
                suppressRotation=false
                if (!exiting && model.fullscreen && !model.portraitFullscreen && seenLandscape) exit()
                return
            }
            if (exiting || suppressRotation) return
            if (!model.fullscreen) {
                model.fullscreen=true
                model.portraitFullscreen=false
                orientation(fullscreenOrientation())
            }
            seenLandscape=true
            keepFullscreenOnReturn=false
        }
        val observer=LifecycleEventObserver { _,event -> when (event) {
            Lifecycle.Event.ON_RESUME -> {
                active=true; seenLandscape=false; model.foreground()
                // A fresh listener reports the current posture even if the device did not move in the background.
                listener=object: OrientationEventListener(activity) {
                    override fun onOrientationChanged(angle: Int) {
                        if (listener===this) rotation.update(angle, ::confirmedPosture)
                    }
                }
                listener?.takeIf { it.canDetectOrientation() }?.enable()
            }
            Lifecycle.Event.ON_PAUSE -> { model.endTemporarySpeed(); active=false; stopListening(); if (model.fullscreen) keepFullscreenOnReturn=true }
            Lifecycle.Event.ON_STOP -> model.background()
            else -> Unit
        } }
        lifecycle.addObserver(observer)
        onDispose { stopListening(); lifecycle.removeObserver(observer) }
    }
    val controller=remember(activity) { WindowCompat.getInsetsController(activity.window,activity.window.decorView) }
    DisposableEffect(controller,active,presentedFullscreen,landscape,app.darkAppearance) {
        if (active) {
            controller.isAppearanceLightStatusBars=!presentedFullscreen && !app.darkAppearance
            controller.isAppearanceLightNavigationBars=!presentedFullscreen && !app.darkAppearance
            if (presentedFullscreen) { controller.systemBarsBehavior=WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE; controller.hide(WindowInsetsCompat.Type.systemBars()) }
            else controller.show(WindowInsetsCompat.Type.systemBars())
        }
        onDispose { }
    }
    DisposableEffect(controller) { onDispose { if (!activity.isChangingConfigurations) { controller.isAppearanceLightStatusBars=!app.darkAppearance; controller.isAppearanceLightNavigationBars=!app.darkAppearance; controller.show(WindowInsetsCompat.Type.systemBars()) } } }
    Column(Modifier.fillMaxSize().then(if (presentedFullscreen) Modifier else Modifier.safeDrawingPadding())) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val ratio=model.aspectRatio
            val height=if (presentedFullscreen) maxHeight else min(maxWidth.value/ratio,maxHeight.value*.5f).dp
            Column {
                PlayerSurface(app,model,Modifier.fillMaxWidth().height(height),::toggleFullscreen,::exit,presentedFullscreen,landscape)
                if (!presentedFullscreen) VideoInformation(app,model,commentComposer)
            }
            WatchLaterNotice(app.watchLater.toggleMessage, Modifier.align(Alignment.BottomCenter)
                .windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 16.dp)
                .padding(bottom = if (presentedFullscreen) 88.dp else 16.dp))
        }
    }
    if (model.settings && !(presentedFullscreen && landscape)) PlayerSettings(model)
}
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable private fun PlayerSurface(app: AppModel,model: PlaybackModel,modifier: Modifier,toggleFullscreen: () -> Unit,exit: () -> Unit,fullscreen: Boolean,landscape: Boolean) {
    val context=LocalContext.current
    val window=checkNotNull(LocalActivity.current).window
    val audio=remember(context) { context.getSystemService(AudioManager::class.java) }
    val rtl=LocalLayoutDirection.current==LayoutDirection.Rtl
    var dragging by remember { mutableStateOf(false) }
    var dragPosition by remember { mutableLongStateOf(0L) }
    var previewDuration by remember { mutableLongStateOf(0L) }
    var surfacePosition by remember { mutableStateOf<Long?>(null) }
    var surfaceActive by remember { mutableStateOf(false) }
    var cancelSeek by remember { mutableStateOf(false) }
    var gestureHint by remember(fullscreen, model.part?.cid) { mutableStateOf<String?>(null) }
    var locked by remember(model,fullscreen,model.part?.cid) { mutableStateOf(false) }
    var zoom by remember(model,fullscreen,model.part?.cid) { mutableFloatStateOf(1f) }
    var interaction by remember { mutableIntStateOf(0) }
    val latestExit by rememberUpdatedState(exit)
    fun toggleControls() { model.controlsVisible=!model.controlsVisible; interaction++ }
    val accessible=remember { (context.getSystemService(android.content.Context.ACCESSIBILITY_SERVICE) as android.view.accessibility.AccessibilityManager).isTouchExplorationEnabled }
    LaunchedEffect(model.controlsVisible,interaction,dragging,surfaceActive,model.settings,model.error) {
        if (model.controlsVisible && !dragging && !surfaceActive && !model.settings && model.error==null && !accessible) {
            delay(1500); model.controlsVisible=false
        }
    }
    LaunchedEffect(gestureHint,surfaceActive) { if (gestureHint!=null && !surfaceActive) { delay(700); gestureHint=null } }
    var inlineBrightness by remember(window, model) { mutableStateOf<Float?>(null) }
    SideEffect {
        if (fullscreen) {
            if (inlineBrightness == null) inlineBrightness = window.attributes.screenBrightness
        } else {
            inlineBrightness?.let { brightness ->
                window.attributes = window.attributes.apply { screenBrightness = brightness }
                inlineBrightness = null
            }
        }
    }
    DisposableEffect(window, model) {
        val previous=window.attributes.screenBrightness
        onDispose {
            if (window.attributes.screenBrightness!=previous) {
                window.attributes=window.attributes.apply { screenBrightness=previous }
            }
        }
    }
    BoxWithConstraints(modifier.background(Color.Black)) {
        var danmakuView by remember { mutableStateOf<DanmakuView?>(null) }
        AndroidView(factory={ c -> FrameLayout(c).apply {
            addView(PlayerView(c).apply { player=model.player; useController=false; setKeepContentOnPlayerReset(true); setShutterBackgroundColor(android.graphics.Color.TRANSPARENT) },FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.MATCH_PARENT))
            addView(DanmakuView(c).also { danmakuView=it },FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.MATCH_PARENT))
        } },update={ frame ->
            (frame.getChildAt(0) as PlayerView).videoSurfaceView?.let { it.scaleX=zoom; it.scaleY=zoom }
            danmakuView?.update(model.player,model.danmakuItems,model.danmaku,model.danmakuFont,model.danmakuArea,model.danmakuOpacity,model.controlsVisible && !locked)
        },onRelease={ frame -> (frame.getChildAt(0) as PlayerView).player=null },modifier=Modifier.fillMaxSize())
        val portrait=maxHeight>maxWidth
        Box(Modifier.matchParentSize().semantics {
            contentDescription="视频画面"
            stateDescription=if (locked) "手势已锁定" else if (model.error!=null) "播放失败" else if (model.buffering) "正在加载" else if (model.playing) "播放中" else "已暂停"
            onClick(if (model.controlsVisible) "隐藏播放控件" else "显示播放控件") { toggleControls(); true }
        }.pointerInput(model,fullscreen,portrait,locked,model.part?.cid,model.playback?.quality,model.settings) {
            var originPosition=0L
            var seekDuration=0L
            var brightness=0f
            var volume=0
            var maximumVolume=1
            fun seekTarget(fraction: Float) = (originPosition+(fraction*minOf(seekDuration,60000L)).toLong()).coerceIn(0L,seekDuration)
            fun updateLevel(drag: PlayerDrag,fraction: Float) {
                if (drag==PlayerDrag.BRIGHTNESS) {
                    val level=(brightness+fraction).coerceIn(.04f,1f)
                    if (window.attributes.screenBrightness!=level) window.attributes=window.attributes.apply { screenBrightness=level }
                    gestureHint="亮度 ${(window.attributes.screenBrightness * 100).roundToInt()}%"
                } else {
                    val level=(volume+fraction*maximumVolume).roundToInt().coerceIn(0,maximumVolume)
                    val current=audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                    val actual=if (level!=current && !audio.isVolumeFixed) {
                        try { audio.setStreamVolume(AudioManager.STREAM_MUSIC,level,0) } catch (_: SecurityException) { }
                        audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                    } else current
                    gestureHint="音量 ${(actual * 100f / maximumVolume).roundToInt()}%"
                }
            }
            detectPlayerSurfaceGestures(fullscreen,portrait,locked,
                onTap=::toggleControls,
                onDoubleTap={ if (model.playback!=null) { model.toggle(); interaction++ } },
                onHold={ held ->
                    if (held) {
                        if (model.beginTemporarySpeed()) { surfaceActive=true; gestureHint=null }
                    } else {
                        model.endTemporarySpeed(); surfaceActive=false
                    }
                },
                onDrag={ drag,phase,fraction -> when (phase) {
                    PlayerDragPhase.START -> {
                        surfaceActive=true; gestureHint=null
                        when (drag) {
                            PlayerDrag.SEEK -> {
                                seekDuration=if (model.playback==null) 0 else model.player.duration.takeIf { it>0 } ?: model.duration
                                originPosition=model.player.currentPosition.coerceAtLeast(0)
                                if (seekDuration>0) { previewDuration=seekDuration; model.controlsVisible=true }
                            }
                            PlayerDrag.BRIGHTNESS -> brightness=window.attributes.screenBrightness.takeIf { it>=0f }
                                ?: Settings.System.getInt(context.contentResolver,Settings.System.SCREEN_BRIGHTNESS,128)/255f
                            PlayerDrag.VOLUME -> {
                                maximumVolume=audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                                volume=audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                            }
                            PlayerDrag.DISMISS -> Unit
                        }
                    }
                    PlayerDragPhase.UPDATE,PlayerDragPhase.CANCEL_ZONE -> when (drag) {
                        PlayerDrag.SEEK -> if (seekDuration>0) {
                            surfacePosition=seekTarget(fraction)
                            cancelSeek=phase==PlayerDragPhase.CANCEL_ZONE
                        }
                        PlayerDrag.BRIGHTNESS,PlayerDrag.VOLUME -> updateLevel(drag,fraction)
                        PlayerDrag.DISMISS -> Unit
                    }
                    PlayerDragPhase.COMMIT,PlayerDragPhase.CANCEL -> {
                        if (phase==PlayerDragPhase.COMMIT) {
                            when (drag) {
                                PlayerDrag.SEEK -> if (seekDuration>0) model.seek(seekTarget(fraction))
                                PlayerDrag.BRIGHTNESS,PlayerDrag.VOLUME -> updateLevel(drag,fraction)
                                PlayerDrag.DISMISS -> Unit
                            }
                        } else { gestureHint=null }
                        surfacePosition=null; cancelSeek=false; surfaceActive=false; interaction++
                    }
                } },
                onDismiss={ latestExit() },
                onTwoFingerTap={ model.danmaku(!model.danmaku); gestureHint=if (model.danmaku) "弹幕已开启" else "弹幕已关闭" },
                onPinch={ factor ->
                    zoom=(zoom*factor).coerceIn(1f,2f)
                    gestureHint="画面缩放 ${(zoom*100).roundToInt()}%"
                }
            )
        })
        if (model.subtitleText.isNotEmpty()) Text(model.subtitleText,Modifier.align(Alignment.BottomCenter).padding(horizontal=22.dp).padding(bottom=if (model.controlsVisible && !locked) 96.dp else 16.dp).background(Color.Black.copy(alpha=.65f)).padding(horizontal=6.dp,vertical=2.dp),color=Color.White,fontSize=15.sp,lineHeight=20.sp,maxLines=2,overflow=TextOverflow.Ellipsis)
        val preview=surfacePosition ?: dragPosition.takeIf { dragging }
        if (model.buffering && preview==null && gestureHint==null) Row(Modifier.align(Alignment.Center).background(Color.Black.copy(alpha=.6f),androidx.compose.foundation.shape.RoundedCornerShape(10.dp)).padding(14.dp),verticalAlignment=Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(20.dp),color=Pink,strokeWidth=2.dp); Spacer(Modifier.width(10.dp)); Text(if (model.preparing) "正在加载…" else "正在缓冲…",color=Color.White,fontSize=13.sp) }
        val progressHint=preview?.let { playbackTime(it,previewDuration) }
        (progressHint ?: gestureHint ?: model.seekHint)?.let { message ->
            Column(Modifier.align(Alignment.Center).background(Color.Black.copy(alpha=.65f),androidx.compose.foundation.shape.RoundedCornerShape(8.dp)).padding(horizontal=12.dp,vertical=8.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                Text(message,color=Color.White,fontSize=14.sp)
                if (cancelSeek) Text("松手取消",color=Color.White,fontSize=12.sp)
            }
        }
        model.error?.let { message -> Column(Modifier.align(Alignment.Center).background(Color.Black.copy(alpha=.8f)).padding(16.dp),horizontalAlignment=Alignment.CenterHorizontally) { Text(message,color=Color.White,fontSize=13.sp); TextButton(onClick=model::retry) { Text("重新加载",color=Color.White) } } }
        val floatingControlColors = IconButtonDefaults.iconButtonColors(containerColor = Color.Black.copy(alpha = .45f))
        if (model.controlsVisible && locked) {
            Box(Modifier.align(Alignment.TopStart).windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal=8.dp)) {
                IconButton(onClick={ locked=false; interaction++ }, colors=floatingControlColors) { Icon(Icons.Rounded.Lock,"解锁播放器",tint=Color.White) }
            }
        }
        if (model.controlsVisible && !locked) Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal=8.dp)) {
            Row(Modifier.fillMaxWidth()) {
                if (fullscreen) IconButton(onClick=exit, colors=floatingControlColors) { Icon(Icons.Rounded.ArrowBack,"退出全屏",tint=Color.White) }
                Spacer(Modifier.weight(1f))
                if (fullscreen) IconButton(onClick={ locked=true; model.controlsVisible=accessible; interaction++ }, colors=floatingControlColors) { Icon(Icons.Rounded.LockOpen,"锁定播放器",tint=Color.White) }
                model.detail?.video?.let { video ->
                    WatchLaterButton(app, video, Modifier.size(48.dp), onTap = { interaction++ })
                }
            }
            Spacer(Modifier.weight(1f))
            Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
                    val playedTrack = Pink
                    val sliderDuration=(if (preview!=null) previewDuration else model.duration).coerceAtLeast(1)
                    Slider(value=(preview ?: model.position).toFloat().coerceIn(0f,sliderDuration.toFloat()),
                        onValueChange={ model.seek(it.toLong()); interaction++ },enabled=model.duration>0,valueRange=0f..sliderDuration.toFloat(),
                        modifier=Modifier.fillMaxWidth().heightIn(min=44.dp).semantics {
                            contentDescription="播放进度"; stateDescription=playbackTime(preview ?: model.position,sliderDuration)
                        }.pointerInput(model,model.part?.cid,model.playback?.quality,model.settings,rtl) {
                            var duration=0L
                            fun position(fraction: Float) = ((if (rtl) 1f-fraction else fraction)*duration).toLong()
                            detectSeekBarScrub(onPreview={ fraction ->
                                if (fraction==null) dragging=false
                                else {
                                    if (!dragging) {
                                        duration=model.player.duration.takeIf { it>0 } ?: model.duration
                                        previewDuration=duration
                                    }
                                    dragging=duration>0; dragPosition=position(fraction)
                                }
                            },onCommit={ fraction -> if (duration>0) { model.seek(position(fraction)); interaction++ } })
                        },
                        thumb={ Spacer(Modifier.size(12.dp)) },
                        track={ state -> Canvas(Modifier.fillMaxWidth().height(12.dp)) {
                            val fraction=(state.value/sliderDuration).coerceIn(0f,1f)
                            val start=Offset(if (layoutDirection==LayoutDirection.Rtl) size.width else 0f,center.y)
                            val end=Offset(size.width-start.x,center.y)
                            drawLine(Color(0xFF777777), start, end, 2.dp.toPx(), StrokeCap.Round)
                            val target=Offset(start.x+(end.x-start.x)*fraction,center.y)
                            drawLine(playedTrack, start, target, 2.dp.toPx(), StrokeCap.Round)
                            drawCircle(Color.Black.copy(alpha = .78f), 6.dp.toPx(), target)
                            drawCircle(Color.White, 5.dp.toPx(), target)
                        } })
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick={ model.toggle(); interaction++ }) {
                    PlaybackControlIcon(if (model.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, if (model.playing) "暂停" else "播放")
                }
                val timeShadow = with(LocalDensity.current) {
                    Shadow(Color.Black, Offset(0f, .75.dp.toPx()), 2.dp.toPx())
                }
                Text(playbackTime(preview ?: model.position, if (preview != null) previewDuration else model.duration),
                    color = Color.White, fontSize = 12.sp, style = LocalTextStyle.current.copy(shadow = timeShadow))
                Spacer(Modifier.weight(1f))
                IconButton(onClick={ model.settings=true; interaction++ }) { PlaybackControlIcon(Icons.Rounded.Settings, "播放设置") }
                IconButton(onClick=toggleFullscreen) {
                    PlaybackControlIcon(if (fullscreen) Icons.Rounded.FullscreenExit else Icons.Rounded.Fullscreen, if (fullscreen) "退出全屏" else "全屏")
                }
            }
        }
        if (model.settings && fullscreen && landscape) {
            val width = (maxWidth * .48f).coerceAtMost(360.dp)
            val height = (maxHeight - 24.dp).coerceAtLeast(0.dp)
            Popup(alignment = Alignment.CenterEnd, onDismissRequest = { model.settings = false },
                properties = PopupProperties(focusable = true)) {
                Box(Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)).padding(end = 12.dp)) {
                    Surface(Modifier.width(width).heightIn(max = height), shape = RoundedCornerShape(16.dp),
                        color = MaterialTheme.colorScheme.surfaceContainer, shadowElevation = 8.dp) {
                        PlayerSettingsOptions(model, Modifier.fillMaxWidth())
                    }
                }
            }
        }
    }
}

@Composable private fun PlaybackControlIcon(image: ImageVector, description: String) {
    val painter = rememberVectorPainter(image)
    Icon(painter, description, tint = Color.White, modifier = Modifier.drawBehind {
        val edge = .7.dp.toPx()
        val outline = ColorFilter.tint(Color.Black.copy(alpha = .75f))
        with(painter) {
            translate(left = -edge) { draw(size, colorFilter = outline) }
            translate(left = edge) { draw(size, colorFilter = outline) }
            translate(top = -edge) { draw(size, colorFilter = outline) }
            translate(top = edge) { draw(size, colorFilter = outline) }
        }
    })
}

private fun playbackTime(position: Long,duration: Long): String {
    fun format(milliseconds: Long): String {
        val seconds=milliseconds/1000
        return if (duration>=3600000L) String.format(Locale.ROOT,"%02d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60)
        else String.format(Locale.ROOT,"%02d:%02d",seconds/60,seconds%60)
    }
    return "${format(position.coerceIn(0L,duration))} / ${format(duration)}"
}
@Composable private fun VideoInformation(app: AppModel,model: PlaybackModel,commentComposer: VideoCommentComposerState) {
    val list=rememberLazyListState(model.informationIndex,model.informationOffset)
    DisposableEffect(list) { onDispose { model.informationIndex=list.firstVisibleItemIndex; model.informationOffset=list.firstVisibleItemScrollOffset } }
    var coinDialog by remember { mutableStateOf(false) }; var favoriteDialog by remember { mutableStateOf(false) }
    var downloadDialog by remember { mutableStateOf(false) }
    val detail=model.detail
    val cached=model.offline || app.downloads.items.any { it.video.bvid==detail?.video?.bvid && it.part.cid==model.part?.cid && app.downloads.file(it)!=null }
    LazyColumn(state=list,modifier=Modifier.fillMaxSize()) {
        if (detail==null) item { ErrorNotice(model.error,model::retry) } else {
            item { Column(Modifier.padding(horizontal=16.dp)) {
                Row(Modifier.padding(top=14.dp),verticalAlignment=Alignment.CenterVertically) { Avatar(detail.video.owner,38) { app.open(Route.Creator(detail.video.owner)) }; Text(detail.video.owner.name,Modifier.weight(1f).padding(horizontal=10.dp).heightIn(min=44.dp).clickable { app.open(Route.Creator(detail.video.owner)) }.wrapContentHeight(Alignment.CenterVertically),fontSize=14.sp,maxLines=2,overflow=TextOverflow.Ellipsis); FollowButton(app,detail.video.owner.mid) }
                Text(detail.video.title,Modifier.padding(top=14.dp),fontSize=17.sp,lineHeight=25.sp,fontWeight=FontWeight.SemiBold)
                Text("${count(detail.video.views)}播放",Modifier.padding(top=6.dp),fontSize=11.sp,color=Muted)
                VideoActions(model,cached,onCoin={ if (app.requireLogin()) coinDialog=true },onFavorite={ if (app.requireLogin()) favoriteDialog=true },onDownload={ if (cached) app.open(Route.Downloads) else if (app.requireLogin()) downloadDialog=true })
                HorizontalDivider(Modifier.padding(top=12.dp),thickness=.5.dp,color=if (LocalDarkAppearance.current) MaterialTheme.colorScheme.outlineVariant else Color(0xffe9e9ee))
            } }
            item { if (model.networkAvailable) { ErrorNotice(model.metadataError,model::refreshOnlineContent); ErrorNotice(model.supportError,model::readEngagement) }; ErrorNotice(app.historyError) }
            if (detail.parts.size>1) item { Column(Modifier.padding(16.dp)) { Text("分P",fontWeight=FontWeight.Medium); FlowRow(horizontalArrangement=Arrangement.spacedBy(6.dp)) { detail.parts.forEach { p -> FilterChip(selected=model.part?.cid==p.cid,onClick={ model.selectPart(p) },label={ Text("P${p.page} ${p.title}",maxLines=2,overflow=TextOverflow.Ellipsis) }) } } } }
            if (detail.description.isNotBlank()) item {
                Column {
                    VideoSectionButton("视频简介", model.descriptionExpanded, model::toggleDescriptionExpanded)
                    Text(detail.description, modifier = Modifier.padding(horizontal = 16.dp),
                        maxLines = if (model.descriptionExpanded) Int.MAX_VALUE else 3,
                        fontSize = 13.sp, color = Muted, overflow = TextOverflow.Ellipsis)
                }
            }
            item { VideoSectionButton("评论", model.commentsExpanded, model::toggleCommentsExpanded) }
            if (model.commentsExpanded) {
                commentItems(app,model.videoComments,commentComposer,"${detail.video.aid}",1,showPagination=model.networkAvailable)
                if (!model.networkAvailable) item { OfflineCommentsNotice(model.offline,model::refreshOnlineContent) }
            }
        }
    }
    if (coinDialog && detail!=null) CoinDialog(model) { coinDialog=false }
    if (favoriteDialog && detail!=null) FavoriteDialog(app,model) { favoriteDialog=false }
    if (downloadDialog) DownloadOptions(app,model) { downloadDialog=false }
    if (commentComposer.visible) CommentComposerSheet(model.videoComments,commentComposer)
}

@Composable private fun VideoSectionButton(title: String, expanded: Boolean, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.padding(horizontal = 8.dp).semantics {
        stateDescription = if (expanded) "已展开" else "已收起"
    }) {
        Text(title, fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurface)
        Spacer(Modifier.width(4.dp))
        Icon(if (expanded) Icons.Rounded.ExpandMore else Icons.Rounded.ChevronRight, null,
            Modifier.size(16.dp), tint = Muted)
    }
}

@Composable private fun VideoActions(model: PlaybackModel,cached: Boolean,onCoin: () -> Unit,onFavorite: () -> Unit,onDownload: () -> Unit) {
    val statistics=model.statistics; val state=model.engagement
    var charging by remember { mutableStateOf(false) }
    var shareDialog by remember(model.detail?.video?.bvid, model.part?.cid) { mutableStateOf(false) }
    val charge by animateFloatAsState(if (charging) 1f else 0f,tween(if (charging) 1500 else 0,easing=LinearEasing),label="三连蓄力")
    val scope=rememberCoroutineScope()
    val currentState by rememberUpdatedState(state)
    val canOpenPanels=model.networkAvailable && model.detailLoaded
    val busy by rememberUpdatedState(model.actionBusy || !canOpenPanels)
    val press=remember(model) { LikePress(scope,{ !busy && currentState?.complete!=true },{ model.write(VideoWrite.Like(currentState?.liked!=true)) },{ model.write(VideoWrite.Triple) },{ charging=it }) }
    val pressLifecycle=LocalLifecycleOwner.current.lifecycle
    DisposableEffect(press,pressLifecycle) {
        val observer=LifecycleEventObserver { _,event -> if (event==Lifecycle.Event.ON_PAUSE) press.cancel() }
        pressLifecycle.addObserver(observer)
        onDispose { pressLifecycle.removeObserver(observer); press.cancel() }
    }
    @Composable fun Total(value: Long?) {
        BasicText(value?.toString() ?: "—", style=LocalTextStyle.current.copy(fontSize=13.sp,color=Muted),
            maxLines=1, autoSize=TextAutoSize.StepBased(minFontSize=9.sp,maxFontSize=13.sp))
    }
    @Composable fun Like(modifier: Modifier) {
        Column(modifier.heightIn(min=58.dp).semantics(mergeDescendants=true) {
            role=Role.Button
            onClick("点赞") { if (!busy) model.write(VideoWrite.Like(currentState?.liked!=true)); true }
            customActions=listOf(CustomAccessibilityAction("一键三连") { if (!busy && currentState?.complete!=true) model.write(VideoWrite.Triple); true })
        }.pointerInput(press) {
            val threshold=22.dp.toPx()
            awaitEachGesture {
                val down=awaitFirstDown(requireUnconsumed=false)
                if (!busy) {
                    press.begin(); var release=false
                    try {
                        while (true) {
                            val event=awaitPointerEvent(); val change=event.changes.firstOrNull { it.id==down.id } ?: break
                            if (change.isConsumed || (change.position-down.position).getDistance()>threshold || change.position.x<0 || change.position.x>size.width || change.position.y<0 || change.position.y>size.height) break
                            if (change.changedToUpIgnoreConsumed()) { release=true; break }
                        }
                    } finally { if (release) press.end() else press.cancel() }
                }
            }
        },horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.Center) {
            Box(contentAlignment=Alignment.Center) { if (charging) CircularProgressIndicator(progress={ charge },modifier=Modifier.size(34.dp),color=Pink,strokeWidth=2.dp); BiliActionIcon(BiliActionKind.LIKE,"点赞，长按一键三连",state?.liked==true) }
            Spacer(Modifier.height(9.dp)); Total(statistics?.likes)
        }
    }
    @Composable fun Action(modifier: Modifier,kind: BiliActionKind,label: String,total: Long?,selected: Boolean,onClick: () -> Unit) {
        TextButton(onClick=onClick,enabled=canOpenPanels,modifier=modifier.heightIn(min=58.dp),contentPadding=PaddingValues(0.dp)) {
            Column(horizontalAlignment=Alignment.CenterHorizontally) { BiliActionIcon(kind,label,selected); Spacer(Modifier.height(9.dp)); Total(total) }
        }
    }
    ActionBarLayout(Modifier.padding(top=10.dp,bottom=2.dp),
        like={ Like(it) },
        coin={ Action(it,BiliActionKind.COIN,"投币",statistics?.coins,(state?.coins ?: 0)>0,onCoin) },
        favorite={ Action(it,BiliActionKind.FAVORITE,"收藏",statistics?.favorites,state?.favorite==true,onFavorite) },
        share={ TextButton(onClick={ press.cancel(); shareDialog=true },modifier=it.heightIn(min=58.dp),contentPadding=PaddingValues(0.dp)) {
            Column(horizontalAlignment=Alignment.CenterHorizontally) {
                Icon(Icons.Rounded.Reply,"转发",Modifier.size(22.dp).graphicsLayer { scaleX=-1f },tint=Muted)
                Spacer(Modifier.height(9.dp)); Text("转发",fontSize=13.sp,color=Muted)
            }
        } },
        download={ TextButton(onClick=onDownload,modifier=it.heightIn(min=58.dp),contentPadding=PaddingValues(0.dp)) {
            Column(horizontalAlignment=Alignment.CenterHorizontally) {
                if (cached) Icon(Icons.Rounded.CheckCircleOutline,"已缓存，查看缓存",Modifier.size(22.dp),tint=Pink) else BiliActionIcon(BiliActionKind.DOWNLOAD,"下载")
                Spacer(Modifier.height(9.dp)); Text(if (cached) "已缓存" else "缓存",fontSize=13.sp,color=if (cached) Pink else Muted)
            }
        } })
    if (shareDialog) model.detail?.let { detail ->
        VideoShareSheet(detail.video.bvid,detail.video.title,model.part?.page ?: 1) { shareDialog=false }
    }
}
@Composable internal fun OfflineCommentsNotice(cachedPlayback: Boolean,retry: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=20.dp).background(Soft,androidx.compose.foundation.shape.RoundedCornerShape(12.dp)).padding(20.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Rounded.WifiOff,null,Modifier.size(28.dp),tint=Muted)
        Text("当前处于离线状态",fontSize=14.sp,color=MaterialTheme.colorScheme.onSurface)
        Text(if (cachedPlayback) "缓存视频可继续播放，联网后即可查看评论。" else "连接网络后即可查看评论。",fontSize=12.sp,color=Muted,textAlign=androidx.compose.ui.text.style.TextAlign.Center)
        TextButton(onClick=retry,modifier=Modifier.heightIn(min=44.dp)) { Text("重新加载") }
    }
}
@Composable private fun CoinDialog(model: PlaybackModel,close: () -> Unit) {
    val detail=model.detail ?: return; val current=model.engagement
    var selected by remember { mutableIntStateOf(1) }; var like by remember { mutableStateOf(true) }
    val remaining=detail.coinLimit-(current?.coins ?: 0)
    AlertDialog(onDismissRequest=close,title={ Text("投币") },text={ Column {
        if (current==null) Text("请先刷新互动状态。") else if (remaining<=0) Text("本视频已投满硬币。") else { Row { (1..remaining).forEach { n -> FilterChip(selected=selected==n,onClick={ selected=n },label={ Text("${n}枚") },modifier=Modifier.padding(end=8.dp)) } }; Row(verticalAlignment=Alignment.CenterVertically) { Checkbox(like,onCheckedChange={ like=it }); Text("同时点赞") } }
    } },confirmButton={ if (remaining>0 && current!=null) TextButton(onClick={ model.write(VideoWrite.Coin(current.coins+selected,like)); close() },enabled=!model.actionBusy && model.networkAvailable) { Text("确定") } },dismissButton={ TextButton(onClick=close) { Text("取消") } })
}
@Composable private fun FavoriteDialog(app: AppModel,model: PlaybackModel,close: () -> Unit) {
    val detail=model.detail ?: return; val scope=rememberCoroutineScope()
    var folders by remember { mutableStateOf<List<Folder>?>(null) }; var selected by remember { mutableStateOf(emptySet<Long>()) }; var error by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    var readAttempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(detail.video.aid,readAttempt) {
        // Deliver network completion on the main looper, independent of dialog frame dispatch.
        withContext(Dispatchers.Main.immediate) {
            error=null
            try {
                val loaded=withTimeoutOrNull(10_000) { app.repository.videoFolders(detail) }
                    ?: throw BiliFailure("NETWORK","读取收藏夹超时，请重试。")
                androidx.compose.runtime.snapshots.Snapshot.withMutableSnapshot { selected=loaded.filter { it.selected }.map { it.id }.toSet(); folders=loaded }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error=e.message ?: "收藏夹暂时无法读取，请重新打开重试。" }
        }
    }
    FavoriteSheet(
        folders=folders, selected=selected, error=error, creating=creating,
        canConfirm=!model.actionBusy && model.networkAvailable,
        retry={ readAttempt++ },
        onSelection={ selected=it }, close=close,
        confirm={ model.write(VideoWrite.Favorite(selected)); close() },
        create={ title ->
            if (!creating) {
                creating=true
                scope.launch {
                    try {
                        val folder=app.repository.createFolder(title)
                        folders=folders.orEmpty()+folder; selected=selected+folder.id; error=null
                    } catch (e: CancellationException) { throw e }
                    catch (e: Exception) { error=e.message }
                    finally { creating=false }
                }
            }
        }
    )
}
@Composable private fun PlayerSettings(model: PlaybackModel) {
    ModalBottomSheet(onDismissRequest={ model.settings=false },sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),dragHandle=null) {
        PlayerSettingsOptions(model, Modifier.weight(1f, fill=false).navigationBarsPadding())
    }
}

@Composable private fun PlayerSettingsOptions(model: PlaybackModel, modifier: Modifier) {
    val titleStyle = MaterialTheme.typography.titleLarge.copy(fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
    val optionStyle = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Normal)
    LazyColumn(modifier, contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("播放设置", style = titleStyle) }
        item {
            val qualities = model.playback?.qualities.orEmpty()
            PlayerOptionGroup("清晰度", optionStyle, qualities, { it.id == model.playback?.quality },
                { model.chooseQuality(it.id) }, { it.label }, "暂无可切换清晰度")
        }
        item {
            PlayerOptionGroup("倍速", optionStyle, listOf(.5f, .75f, 1f, 1.25f, 1.5f, 2f), { it == model.speed },
                model::speed, { "${it}×" })
        }
        item {
            val tracks = model.tracks
            PlayerOptionGroup("字幕", optionStyle, if (tracks.isEmpty()) emptyList() else listOf(null) + tracks,
                { it?.id == model.subtitle?.id }, model::subtitle, { it?.label ?: "关闭" },
                model.subtitleError ?: "暂无可用字幕")
        }
        item {
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                .toggleable(model.danmaku, role = Role.Switch, onValueChange = model::danmaku),
                verticalAlignment = Alignment.CenterVertically) {
                Text("弹幕", Modifier.weight(1f), style = optionStyle)
                Switch(model.danmaku, onCheckedChange = null)
            }
            ErrorNotice(model.danmakuError)
        }
        if (model.danmaku) {
            item {
                PlayerOptionGroup("字号", optionStyle, listOf(16 to "小", 20 to "标准", 24 to "大"),
                    { it.first == model.danmakuFont }, { model.font(it.first) }, { it.second })
            }
            item {
                PlayerOptionGroup("弹幕占比", optionStyle, listOf(.25f to "1/4", .5f to "1/2", .75f to "3/4", 1f to "全屏"),
                    { it.first == model.danmakuArea }, { model.area(it.first) }, { it.second })
            }
            item {
                PlayerOptionGroup("不透明度", optionStyle, listOf(.5f, .75f, 1f), { it == model.danmakuOpacity },
                    model::opacity, { "${(it * 100).toInt()}%" })
            }
        }
    }
}

@Composable private fun <T> PlayerOptionGroup(
    title: String, style: TextStyle, options: List<T>, selected: (T) -> Boolean, onChoose: (T) -> Unit,
    label: (T) -> String, unavailable: String? = null,
) {
    Text(title, style = style, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (options.isEmpty()) {
        unavailable?.let { Text(it, style = style, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    } else {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            options.forEach { option ->
                FilterChip(selected = selected(option), onClick = { onChoose(option) },
                    label = { Text(label(option), style = style) })
            }
        }
    }
}

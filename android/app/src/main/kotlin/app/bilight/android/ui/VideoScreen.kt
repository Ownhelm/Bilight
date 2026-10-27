@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package app.bilight.android.ui

import android.content.pm.ActivityInfo
import android.view.OrientationEventListener
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.LinearEasing
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.LayoutDirection

import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.viewinterop.AndroidView
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
import kotlin.math.min

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable fun VideoScreen(app: AppModel,route: Route.Watch) {
    val model=remember(route,app.http.generation) { app.playback(route) }
    val activity=checkNotNull(LocalActivity.current)
    val scope=rememberCoroutineScope()
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    val landscape=LocalConfiguration.current.orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE
    val currentLandscape by rememberUpdatedState(landscape)
    var active by remember { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    var suppressRotation by remember { mutableStateOf(false) }
    var seenLandscape by remember { mutableStateOf(false) }
    var exiting by remember { mutableStateOf(false) }
    var keepFullscreenOnReturn by remember(model) { mutableStateOf(model.fullscreen) }
    var portraitTask by remember { mutableStateOf<Job?>(null) }
    fun orientation(value: Int) { if (activity.requestedOrientation!=value) activity.requestedOrientation=value }
    fun exit() {
        if (exiting) return
        portraitTask?.cancel(); exiting=currentLandscape && model.fullscreen
        keepFullscreenOnReturn=false; model.fullscreen=false; model.portraitFullscreen=false
        seenLandscape=false; suppressRotation=true
        orientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
    }
    fun toggleFullscreen() {
        if (exiting) return
        if (model.fullscreen) { exit(); return }
        suppressRotation=false; keepFullscreenOnReturn=false
        model.portraitFullscreen=model.aspectRatio<1f
        model.fullscreen=true; model.controlsVisible=true; seenLandscape=false
        orientation(if (model.portraitFullscreen) ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR else ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE)
    }
    // Change layout only with the target window orientation. The embedded player never stretches first.
    val presentedFullscreen=fullscreenPresentation(model.fullscreen,model.portraitFullscreen,landscape,keepFullscreenOnReturn,exiting)
    BackHandler(model.fullscreen || exiting) { exit() }
    LaunchedEffect(landscape) { if (!landscape) exiting=false }
    DisposableEffect(model) {
        orientation(if (model.fullscreen) ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
        onDispose {
            portraitTask?.cancel()
            if (!activity.isChangingConfigurations) { app.releasePlayback(model); orientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT) }
        }
    }
    DisposableEffect(lifecycle,model) {
        val listener=object: OrientationEventListener(activity) {
            override fun onOrientationChanged(angle: Int) {
                if (!active || exiting || angle==ORIENTATION_UNKNOWN) return
                val horizontal=angle in 60..120 || angle in 240..300
                val vertical=angle in 0..20 || angle in 340..359
                if (horizontal) {
                    portraitTask?.cancel()
                    if (!suppressRotation && !model.fullscreen) {
                        model.fullscreen=true; model.portraitFullscreen=false; keepFullscreenOnReturn=false
                        orientation(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE)
                    }
                    if (model.fullscreen) {
                        seenLandscape=true; keepFullscreenOnReturn=false
                        orientation(ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR)
                    }
                } else if (vertical) {
                    if (suppressRotation) suppressRotation=false
                    if (model.fullscreen && !model.portraitFullscreen && seenLandscape && portraitTask?.isActive!=true) {
                        portraitTask=scope.launch { delay(120); if (active && model.fullscreen) exit() }
                    }
                } else portraitTask?.cancel()
            }
        }
        val observer=LifecycleEventObserver { _,event -> when (event) {
            Lifecycle.Event.ON_RESUME -> { active=true; seenLandscape=false; model.foreground(); if (listener.canDetectOrientation()) listener.enable() }
            Lifecycle.Event.ON_PAUSE -> { active=false; portraitTask?.cancel(); listener.disable(); if (model.fullscreen) keepFullscreenOnReturn=true }
            Lifecycle.Event.ON_STOP -> model.background()
            else -> Unit
        } }
        lifecycle.addObserver(observer)
        onDispose { listener.disable(); lifecycle.removeObserver(observer) }
    }
    val controller=remember(activity) { WindowCompat.getInsetsController(activity.window,activity.window.decorView) }
    DisposableEffect(controller,active,presentedFullscreen,landscape) {
        if (active) {
            controller.isAppearanceLightStatusBars=!presentedFullscreen
            controller.isAppearanceLightNavigationBars=!presentedFullscreen
            if (presentedFullscreen) { controller.systemBarsBehavior=WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE; controller.hide(WindowInsetsCompat.Type.systemBars()) }
            else controller.show(WindowInsetsCompat.Type.systemBars())
        }
        onDispose { }
    }
    DisposableEffect(controller) { onDispose { if (!activity.isChangingConfigurations) { controller.isAppearanceLightStatusBars=true; controller.isAppearanceLightNavigationBars=true; controller.show(WindowInsetsCompat.Type.systemBars()) } } }
    Column(Modifier.fillMaxSize().then(if (presentedFullscreen) Modifier else Modifier.safeDrawingPadding())) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val ratio=model.aspectRatio
            val height=if (presentedFullscreen) maxHeight else min(maxWidth.value/ratio,maxHeight.value*.5f).dp
            Column {
                PlayerSurface(model,Modifier.fillMaxWidth().height(height),::toggleFullscreen,::exit,presentedFullscreen)
                if (!presentedFullscreen) VideoInformation(app,model)
            }
        }
    }
    if (model.settings) PlayerSettings(model)
}
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable private fun PlayerSurface(model: PlaybackModel,modifier: Modifier,toggleFullscreen: () -> Unit,exit: () -> Unit,fullscreen: Boolean) {
    val context=LocalContext.current; val density=LocalDensity.current
    var dragging by remember { mutableStateOf(false) }
    var dragPosition by remember { mutableFloatStateOf(0f) }
    var interaction by remember { mutableIntStateOf(0) }
    val accessible=remember { (context.getSystemService(android.content.Context.ACCESSIBILITY_SERVICE) as android.view.accessibility.AccessibilityManager).isTouchExplorationEnabled }
    LaunchedEffect(model.controlsVisible,interaction,dragging,model.settings,model.error) { if (model.controlsVisible && !dragging && !model.settings && model.error==null && !accessible) { delay(1500); model.controlsVisible=false } }
    BoxWithConstraints(modifier.background(Color.Black)) {
        var danmakuView by remember { mutableStateOf<DanmakuView?>(null) }
        AndroidView(factory={ c -> FrameLayout(c).apply {
            addView(PlayerView(c).apply { player=model.player; useController=false; setKeepContentOnPlayerReset(true); setShutterBackgroundColor(android.graphics.Color.TRANSPARENT) },FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.MATCH_PARENT))
            addView(DanmakuView(c).also { danmakuView=it },FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.MATCH_PARENT))
        } },update={ danmakuView?.update(model.player,model.danmakuItems,model.danmaku,model.danmakuFont,model.danmakuArea,model.danmakuOpacity,model.controlsVisible) },onRelease={ frame -> (frame.getChildAt(0) as PlayerView).player=null },modifier=Modifier.fillMaxSize())
        if (model.controlsVisible) Box(Modifier.matchParentSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha=.25f),Color.Transparent,Color.Transparent,Color.Black.copy(alpha=.4f)))))
        val widthPx=with(density) { maxWidth.toPx() }
        val tracker=remember { VelocityTracker() }; var travel by remember { mutableFloatStateOf(0f) }; var horizontal by remember { mutableFloatStateOf(0f) }; var originX by remember { mutableFloatStateOf(0f) }
        Box(Modifier.matchParentSize().semantics { contentDescription="视频画面"; stateDescription=if (model.error!=null) "播放失败" else if (model.buffering) "正在加载" else if (model.playing) "播放中" else "已暂停" }.pointerInput(widthPx) { detectTapGestures(onTap={ model.controlsVisible=!model.controlsVisible; interaction++ },onDoubleTap={ model.doubleTap(it.x/widthPx); interaction++ }) }.pointerInput(fullscreen,model.portraitFullscreen) {
            if (fullscreen && maxHeight>maxWidth) detectVerticalDragGestures(onDragStart={ travel=0f; horizontal=0f; originX=it.x; tracker.resetTracking() },onVerticalDrag={ change,amount -> travel+=amount; horizontal=change.position.x-originX; tracker.addPosition(change.uptimeMillis,change.position) },onDragEnd={ if (travel>kotlin.math.abs(horizontal)*1.35f && (travel>80*density.density || travel>28*density.density && tracker.calculateVelocity().y>700*density.density)) exit() })
        })
        if (model.subtitleText.isNotEmpty()) Text(model.subtitleText,Modifier.align(Alignment.BottomCenter).padding(horizontal=22.dp).padding(bottom=if (model.controlsVisible) 56.dp else 16.dp).background(Color.Black.copy(alpha=.65f)).padding(horizontal=6.dp,vertical=2.dp),color=Color.White,fontSize=15.sp,lineHeight=20.sp,maxLines=2,overflow=TextOverflow.Ellipsis)
        if (model.buffering && !dragging) Row(Modifier.align(Alignment.Center).background(Color.Black.copy(alpha=.6f),androidx.compose.foundation.shape.RoundedCornerShape(10.dp)).padding(14.dp),verticalAlignment=Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(20.dp),color=Pink,strokeWidth=2.dp); Spacer(Modifier.width(10.dp)); Text(if (model.preparing) "正在加载…" else "正在缓冲…",color=Color.White,fontSize=13.sp) }
        val progressHint=if (dragging) "${clock(dragPosition.toLong()/1000)} / ${clock(model.duration/1000)}" else model.seekHint
        progressHint?.let { Text(it,Modifier.align(Alignment.Center).background(Color.Black.copy(alpha=.65f),androidx.compose.foundation.shape.RoundedCornerShape(8.dp)).padding(horizontal=12.dp,vertical=8.dp),color=Color.White,fontSize=14.sp) }
        model.error?.let { message -> Column(Modifier.align(Alignment.Center).background(Color.Black.copy(alpha=.8f)).padding(16.dp),horizontalAlignment=Alignment.CenterHorizontally) { Text(message,color=Color.White,fontSize=13.sp); TextButton(onClick=model::retry) { Text("重新加载",color=Color.White) } } }
        if (model.controlsVisible) Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal=8.dp)) {
            Row(Modifier.fillMaxWidth()) { if (fullscreen) IconButton(onClick=exit) { Icon(Icons.Rounded.ArrowBack,"退出全屏",tint=Color.White) }; Spacer(Modifier.weight(1f)); IconButton(onClick={ model.settings=true; interaction++ }) { Icon(Icons.Rounded.Settings,"播放设置",tint=Color.White) } }
            Spacer(Modifier.weight(1f))
            Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                IconButton(onClick={ model.toggle(); interaction++ }) { Icon(if (model.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,if (model.playing) "暂停" else "播放",tint=Color.White) }
                Box(Modifier.weight(1f)) {
                    Slider(value=if (dragging) dragPosition else model.position.toFloat().coerceIn(0f,model.duration.coerceAtLeast(1).toFloat()),
                        onValueChange={ dragging=true; dragPosition=it },onValueChangeFinished={ model.seek(dragPosition.toLong()); dragging=false; interaction++ },valueRange=0f..model.duration.coerceAtLeast(1).toFloat(),
                        modifier=Modifier.fillMaxWidth().heightIn(min=44.dp).semantics { contentDescription="播放进度"; stateDescription="${clock(model.position/1000)} / ${clock(model.duration/1000)}" },
                        thumb={ Spacer(Modifier.size(12.dp)) },
                        track={ state -> Canvas(Modifier.fillMaxWidth().height(12.dp)) {
                            val fraction=(state.value/model.duration.coerceAtLeast(1)).coerceIn(0f,1f)
                            val start=Offset(if (layoutDirection==LayoutDirection.Rtl) size.width else 0f,center.y)
                            val end=Offset(size.width-start.x,center.y)
                            drawLine(Color.White.copy(alpha=.2f),start,end,2.dp.toPx(),StrokeCap.Round)
                            val target=Offset(start.x+(end.x-start.x)*fraction,center.y)
                            drawLine(Color.White,start,target,2.dp.toPx(),StrokeCap.Round)
                            drawCircle(Color.White,if (dragging) 6.dp.toPx() else 4.dp.toPx(),target)
                        } })
                }
                IconButton(onClick=toggleFullscreen) { Icon(if (fullscreen) Icons.Rounded.FullscreenExit else Icons.Rounded.Fullscreen,if (fullscreen) "退出全屏" else "全屏",tint=Color.White) }
            }
        }
    }
}
@Composable private fun VideoInformation(app: AppModel,model: PlaybackModel) {
    val list=rememberLazyListState(model.informationIndex,model.informationOffset)
    DisposableEffect(list) { onDispose { model.informationIndex=list.firstVisibleItemIndex; model.informationOffset=list.firstVisibleItemScrollOffset } }
    var coinDialog by remember { mutableStateOf(false) }; var favoriteDialog by remember { mutableStateOf(false) }
    var downloadDialog by remember { mutableStateOf(false) }
    val detail=model.detail
    LazyColumn(state=list,modifier=Modifier.fillMaxSize()) {
        if (detail==null) item { ErrorNotice(model.error,model::retry) } else {
            item { Column(Modifier.padding(horizontal=16.dp)) {
                Row(Modifier.padding(top=14.dp),verticalAlignment=Alignment.CenterVertically) { Avatar(detail.video.owner,38) { app.open(Route.Creator(detail.video.owner)) }; Text(detail.video.owner.name,Modifier.weight(1f).padding(horizontal=10.dp).heightIn(min=44.dp).clickable { app.open(Route.Creator(detail.video.owner)) }.wrapContentHeight(Alignment.CenterVertically),fontSize=14.sp,maxLines=2,overflow=TextOverflow.Ellipsis); FollowButton(app,detail.video.owner.mid) }
                Text(detail.video.title,Modifier.padding(top=14.dp),fontSize=17.sp,lineHeight=25.sp,fontWeight=FontWeight.SemiBold)
                Text("${count(detail.video.views)}播放",Modifier.padding(top=6.dp),fontSize=11.sp,color=Muted)
                if (!model.offline) VideoActions(model,onCoin={ if (app.requireLogin()) coinDialog=true },onFavorite={ if (app.requireLogin()) favoriteDialog=true },onDownload={ if (app.requireLogin()) downloadDialog=true })
                HorizontalDivider(Modifier.padding(top=12.dp),thickness=.5.dp,color=Color(0xffe9e9ee))
            } }
            item { ErrorNotice(model.supportError,model::readEngagement); ErrorNotice(app.historyError) }
            if (detail.parts.size>1) item { Column(Modifier.padding(16.dp)) { Text("分P",fontWeight=FontWeight.Medium); FlowRow(horizontalArrangement=Arrangement.spacedBy(6.dp)) { detail.parts.forEach { p -> FilterChip(selected=model.part?.cid==p.cid,onClick={ model.selectPart(p) },label={ Text("P${p.page} ${p.title}",maxLines=2,overflow=TextOverflow.Ellipsis) }) } } } }
            if (detail.description.isNotBlank()) item { var expanded by remember { mutableStateOf(false) }; Column(Modifier.padding(horizontal=16.dp)) { Text(detail.description,maxLines=if (expanded) Int.MAX_VALUE else 3,fontSize=13.sp,color=Muted,overflow=TextOverflow.Ellipsis); TextButton(onClick={ expanded=!expanded }) { Text(if (expanded) "收起简介" else "展开简介") } } }
            if (!model.offline) item { TextButton(onClick={ model.commentsExpanded=!model.commentsExpanded },modifier=Modifier.padding(horizontal=8.dp)) { Text(if (model.commentsExpanded) "评论" else "展开评论",fontSize=17.sp,color=MaterialTheme.colorScheme.onSurface) } }
            if (!model.offline && model.commentsExpanded) { items(model.comments,key={ it.id }) { CommentRow(app,it) }; item { PageMore(model.commentsBusy,model.commentsMore,model.commentsError,model::loadComments) } }
        }
    }
    if (coinDialog && detail!=null) CoinDialog(model) { coinDialog=false }
    if (favoriteDialog && detail!=null) FavoriteDialog(app,model) { favoriteDialog=false }
    if (downloadDialog) DownloadOptions(app,model) { downloadDialog=false }
}
@Composable private fun VideoActions(model: PlaybackModel,onCoin: () -> Unit,onFavorite: () -> Unit,onDownload: () -> Unit) {
    val statistics=model.detail?.statistics ?: return; val state=model.engagement
    var charging by remember { mutableStateOf(false) }
    val charge by animateFloatAsState(if (charging) 1f else 0f,tween(if (charging) 1500 else 0,easing=LinearEasing),label="三连蓄力")
    val scope=rememberCoroutineScope()
    val currentState by rememberUpdatedState(state)
    val busy by rememberUpdatedState(model.actionBusy)
    val press=remember(model) { LikePress(scope,{ !busy && currentState?.complete!=true },{ model.write(VideoWrite.Like(currentState?.liked!=true)) },{ model.write(VideoWrite.Triple) },{ charging=it }) }
    val pressLifecycle=LocalLifecycleOwner.current.lifecycle
    DisposableEffect(press,pressLifecycle) {
        val observer=LifecycleEventObserver { _,event -> if (event==Lifecycle.Event.ON_PAUSE) press.cancel() }
        pressLifecycle.addObserver(observer)
        onDispose { pressLifecycle.removeObserver(observer); press.cancel() }
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
            Spacer(Modifier.height(9.dp)); Text(count(statistics.likes),fontSize=13.sp,color=Muted)
        }
    }
    @Composable fun Action(modifier: Modifier,kind: BiliActionKind,label: String,total: Long,selected: Boolean,onClick: () -> Unit) {
        TextButton(onClick=onClick,enabled=!model.actionBusy,modifier=modifier.heightIn(min=58.dp),contentPadding=PaddingValues(0.dp)) {
            Column(horizontalAlignment=Alignment.CenterHorizontally) { BiliActionIcon(kind,label,selected); Spacer(Modifier.height(9.dp)); Text(count(total),fontSize=13.sp,color=Muted) }
        }
    }
    ActionBarLayout(Modifier.padding(top=10.dp,bottom=2.dp),
        like={ Like(it) },
        coin={ Action(it,BiliActionKind.COIN,"投币",statistics.coins,(state?.coins ?: 0)>0,onCoin) },
        favorite={ Action(it,BiliActionKind.FAVORITE,"收藏",statistics.favorites,state?.favorite==true,onFavorite) },
        download={ IconButton(onClick=onDownload,modifier=it.heightIn(min=58.dp)) { BiliActionIcon(BiliActionKind.DOWNLOAD,"下载") } })
}
@Composable private fun CoinDialog(model: PlaybackModel,close: () -> Unit) {
    val detail=model.detail ?: return; val current=model.engagement
    var selected by remember { mutableIntStateOf(1) }; var like by remember { mutableStateOf(true) }
    val remaining=detail.coinLimit-(current?.coins ?: 0)
    AlertDialog(onDismissRequest=close,title={ Text("投币") },text={ Column {
        if (current==null) Text("请先刷新互动状态。") else if (remaining<=0) Text("本视频已投满硬币。") else { Row { (1..remaining).forEach { n -> FilterChip(selected=selected==n,onClick={ selected=n },label={ Text("${n}枚") },modifier=Modifier.padding(end=8.dp)) } }; Row(verticalAlignment=Alignment.CenterVertically) { Checkbox(like,onCheckedChange={ like=it }); Text("同时点赞") } }
    } },confirmButton={ if (remaining>0 && current!=null) TextButton(onClick={ model.write(VideoWrite.Coin(current.coins+selected,like)); close() }) { Text("确定") } },dismissButton={ TextButton(onClick=close) { Text("取消") } })
}
@Composable private fun FavoriteDialog(app: AppModel,model: PlaybackModel,close: () -> Unit) {
    val detail=model.detail ?: return; val scope=rememberCoroutineScope()
    var folders by remember { mutableStateOf<List<Folder>?>(null) }; var selected by remember { mutableStateOf(emptySet<Long>()) }; var error by remember { mutableStateOf<String?>(null) }; var title by remember { mutableStateOf("") }
    var creating by remember { mutableStateOf(false) }
    val titleRequester=remember { BringIntoViewRequester() }; var titleFocused by remember { mutableStateOf(false) }
    val keyboardHeight=WindowInsets.ime.getBottom(LocalDensity.current)
    LaunchedEffect(titleFocused,keyboardHeight) { if (titleFocused) { withFrameNanos { }; titleRequester.bringIntoView() } }
    LaunchedEffect(detail.video.aid) {
        // Deliver network completion on the main looper, independent of dialog frame dispatch.
        withContext(Dispatchers.Main.immediate) {
            try {
                val loaded=app.repository.videoFolders(detail)
                androidx.compose.runtime.snapshots.Snapshot.withMutableSnapshot { selected=loaded.filter { it.selected }.map { it.id }.toSet(); folders=loaded }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error=e.message ?: "收藏夹暂时无法读取，请重新打开重试。" }
        }
    }
    AlertDialog(onDismissRequest=close,modifier=Modifier.safeDrawingPadding().imePadding(),properties=DialogProperties(decorFitsSystemWindows=false),title={ Text("收藏到（${selected.size}）") },text={ Column(Modifier.fillMaxWidth().heightIn(max=460.dp).verticalScroll(androidx.compose.foundation.rememberScrollState())) {
        ErrorNotice(error)
        if (folders==null && error==null) Loading()
        TextButton(onClick={ selected=emptySet() },enabled=selected.isNotEmpty()) { Text("取消全部") }
        Column(Modifier.heightIn(max=260.dp).verticalScroll(androidx.compose.foundation.rememberScrollState())) { folders.orEmpty().forEach { folder -> Row(verticalAlignment=Alignment.CenterVertically) { Checkbox(folder.id in selected,onCheckedChange={ checked -> selected=if (checked) selected+folder.id else selected-folder.id },enabled=folder.selected || folder.count<folder.capacity); Column { Text(folder.title); Text("${folder.count}/${folder.capacity}${if (folder.private) " · 私密" else ""}",fontSize=11.sp,color=Muted) } } } }
        OutlinedTextField(title,onValueChange={ title=it },label={ Text("新建公开收藏夹",maxLines=1,overflow=TextOverflow.Ellipsis) },singleLine=true,modifier=Modifier.fillMaxWidth().bringIntoViewRequester(titleRequester).onFocusChanged { titleFocused=it.isFocused })
        TextButton(onClick={ if (!creating) { creating=true; scope.launch { try { val folder=app.repository.createFolder(title); folders=folders.orEmpty()+folder; selected=selected+folder.id; title="" } catch (e: CancellationException) { throw e } catch (e: Exception) { error=e.message } finally { creating=false } } } },enabled=title.isNotBlank() && !creating) { Text(if (creating) "正在新建" else "新建并勾选") }
    } },confirmButton={ TextButton(onClick={ model.write(VideoWrite.Favorite(selected)); close() },enabled=folders!=null && selected!=folders!!.filter { it.selected }.map { it.id }.toSet()) { Text("确定") } },dismissButton={ TextButton(onClick=close) { Text("取消") } })
}
@Composable private fun PlayerSettings(model: PlaybackModel) {
    ModalBottomSheet(onDismissRequest={ model.settings=false },sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),dragHandle=null) { LazyColumn(modifier=Modifier.weight(1f,fill=false).navigationBarsPadding(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        item { Text("播放设置",fontSize=20.sp,fontWeight=FontWeight.SemiBold) }
        item { Text("清晰度",fontSize=13.sp,color=Muted); FlowRow(horizontalArrangement=Arrangement.spacedBy(6.dp)) { model.playback?.qualities.orEmpty().forEach { q -> FilterChip(selected=model.playback?.quality==q.id,onClick={ model.chooseQuality(q.id) },label={ Text(q.label) }) } } }
        item { Text("倍速",fontSize=13.sp,color=Muted); FlowRow(horizontalArrangement=Arrangement.spacedBy(6.dp)) { listOf(.5f,.75f,1f,1.25f,1.5f,2f).forEach { speed -> FilterChip(selected=model.speed==speed,onClick={ model.speed(speed) },label={ Text("${speed}×") }) } } }
        item { Text("字幕",fontSize=13.sp,color=Muted); if (model.tracks.isEmpty()) Text(model.subtitleError ?: "暂无可用字幕",fontSize=13.sp,color=Muted) else FlowRow(horizontalArrangement=Arrangement.spacedBy(6.dp)) { FilterChip(selected=model.subtitle==null,onClick={ model.subtitle(null) },label={ Text("关闭") }); model.tracks.forEach { track -> FilterChip(selected=model.subtitle?.id==track.id,onClick={ model.subtitle(track) },label={ Text(track.label) }) } } }
        item { Row(verticalAlignment=Alignment.CenterVertically) { Text("弹幕",Modifier.weight(1f)); Switch(model.danmaku,onCheckedChange=model::danmaku) }; ErrorNotice(model.danmakuError) }
        if (model.danmaku) {
            item { Text("字号",fontSize=13.sp,color=Muted); FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) { listOf(16 to "小",20 to "中",24 to "大").forEach { (size,label) -> FilterChip(selected=model.danmakuFont==size,onClick={ model.font(size) },label={ Text(label) }) } } }
            item { Text("弹幕占比",fontSize=13.sp,color=Muted); FlowRow(horizontalArrangement=Arrangement.spacedBy(6.dp)) { listOf(.25f to "1/4",.5f to "1/2",.75f to "3/4",1f to "全屏").forEach { (area,label) -> FilterChip(selected=model.danmakuArea==area,onClick={ model.area(area) },label={ Text(label) }) } } }
            item { Text("不透明度",fontSize=13.sp,color=Muted); FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) { listOf(.5f,.75f,1f).forEach { alpha -> FilterChip(selected=model.danmakuOpacity==alpha,onClick={ model.opacity(alpha) },label={ Text("${(alpha*100).toInt()}%") }) } } }
        }
    } }
}

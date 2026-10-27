package app.bilight.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.bilight.android.core.Picture
import kotlin.math.abs

@Composable fun PostGallery(pictures: List<Picture>, selected: Int, close: () -> Unit) {
    val pager=rememberPagerState(initialPage=selected.coerceIn(0,pictures.lastIndex)) { pictures.size }
    Dialog(onDismissRequest=close,properties=DialogProperties(usePlatformDefaultWidth=false,decorFitsSystemWindows=false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            HorizontalPager(pager,modifier=Modifier.fillMaxSize(),beyondViewportPageCount=1) { page ->
                if (abs(page-pager.currentPage)<=1) {
                    var retry by remember(pictures[page].url) { mutableIntStateOf(0) }
                    var load by remember(pictures[page].url,retry) { mutableStateOf(ImageLoadState.LOADING) }
                    var scale by remember(pictures[page].url) { mutableFloatStateOf(1f) }
                    var translation by remember(pictures[page].url) { mutableStateOf(Offset.Zero) }
                    Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center) {
                    key(retry) { RemoteImage(pictures[page].url,"第${page+1}张图片",Modifier.fillMaxSize().pointerInput(Unit) {
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed=false)
                            do {
                                val event=awaitPointerEvent()
                                if (event.changes.count { it.pressed }>=2 || scale>1.01f) {
                                    scale=(scale*event.calculateZoom()).coerceIn(1f,5f)
                                    val offset=translation+event.calculatePan(); val x=size.width*(scale-1)/2; val y=size.height*(scale-1)/2
                                    translation=Offset(offset.x.coerceIn(-x,x),offset.y.coerceIn(-y,y))
                                    event.changes.forEach { it.consume() }
                                }
                            } while (event.changes.any { it.pressed })
                        }
                    }.pointerInput(Unit) { detectTapGestures(onDoubleTap={ scale=if (scale>1.01f) 1f else 2f; translation=Offset.Zero }) }.graphicsLayer { scaleX=scale; scaleY=scale; translationX=translation.x; translationY=translation.y },ContentScale.Fit,onLoadState={ load=it },backgroundColor=Color.Black) }
                    if (load==ImageLoadState.LOADING) CircularProgressIndicator(color=Color.White)
                    if (load==ImageLoadState.FAILED) Column(horizontalAlignment=Alignment.CenterHorizontally) { Text("图片加载失败",color=Color.White); TextButton(onClick={ retry++ }) { Text("重试",color=Color.White) } }
                    }
                }
            }
            Row(Modifier.fillMaxWidth().safeDrawingPadding().padding(horizontal=12.dp),verticalAlignment=Alignment.CenterVertically) {
                Text("${pager.currentPage+1} / ${pictures.size}",color=Color.White)
                Spacer(Modifier.weight(1f)); IconButton(onClick=close) { Icon(Icons.Rounded.Close,"关闭图片",tint=Color.White) }
            }
        }
    }
}

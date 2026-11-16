@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package app.bilight.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.bilight.android.R
import app.bilight.android.core.AppModel
import app.bilight.android.core.Video
import app.bilight.android.core.WatchLaterEntry
import app.bilight.android.core.clock

@Composable internal fun WatchLaterButton(
    app: AppModel,
    video: Video,
    modifier: Modifier = Modifier,
    onTap: () -> Unit = {},
) {
    val model = app.watchLater
    LaunchedEffect(app.sessionRevision, app.user?.mid) { model.warm() }
    val saved = model.saved(video)
    val busy = model.pending(video)
    val action = if (saved == true) "移出稍后再看" else "稍后再看"
    Box(
        modifier.size(44.dp).clip(CircleShape).clickable(enabled = !busy, role = Role.Button) {
            onTap()
            model.toggle(video)
        }.semantics {
            contentDescription = action
            stateDescription = when {
                busy -> "正在同步"
                saved == true -> "已加入"
                saved == false -> "未加入"
                else -> "状态未读取"
            }
        }.testTag("watch-later-${video.bvid}"),
        contentAlignment = Alignment.Center,
    ) {
        if (busy) CircularProgressIndicator(Modifier.size(15.dp), color = Color.White, strokeWidth = 1.5.dp)
        else Icon(
            painterResource(if (saved == true) R.drawable.watch_later_saved else R.drawable.watch_later_unsaved),
            null, Modifier.size(22.dp), tint = Color.Unspecified,
        )
    }
}

@Composable internal fun WatchLaterNotice(message: String?, modifier: Modifier = Modifier) {
    if (message == null) return
    Surface(
        modifier.testTag("watch-later-notification").semantics { liveRegion = LiveRegionMode.Polite },
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .55f)),
        shadowElevation = 6.dp,
    ) {
        Text(message, Modifier.padding(horizontal = 14.dp, vertical = 9.dp), fontSize = 14.sp)
    }
}

private class WatchLaterBrowseState {
    var opened = false
    var index = 0
    var offset = 0
}

@Composable internal fun WatchLaterScreen(app: AppModel) {
    val model = app.watchLater
    val browse = remember(app.sessionRevision) { app.browseState("watch-later") { WatchLaterBrowseState() } }
    val list = rememberLazyListState(browse.index, browse.offset)
    val snackbars = remember { SnackbarHostState() }
    DisposableEffect(list) {
        onDispose { browse.index = list.firstVisibleItemIndex; browse.offset = list.firstVisibleItemScrollOffset }
    }
    var choosing by rememberSaveable { mutableStateOf(false) }
    var confirm by rememberSaveable { mutableStateOf(false) }
    var selected by rememberSaveable { mutableStateOf(longArrayOf()) }
    val items = model.items
    val selection = items.filter { it.aid in selected }
    fun closeSelection() {
        choosing = false
        selected = longArrayOf()
    }
    BackHandler(choosing && !confirm, onBack = ::closeSelection)
    LaunchedEffect(browse) {
        if (!browse.opened) { browse.opened = true; model.load(refresh = true, opening = true) }
    }
    LaunchedEffect(model.undo) {
        val entry = model.undo ?: return@LaunchedEffect
        val result = snackbars.showSnackbar("已移出稍后再看", "撤销", duration = SnackbarDuration.Short)
        if (result == SnackbarResult.ActionPerformed) model.restore(entry)
        model.dismissUndo(entry)
    }
    LaunchedEffect(model.bulkMessage) {
        val message = model.bulkMessage ?: return@LaunchedEffect
        snackbars.showSnackbar(message, duration = SnackbarDuration.Short)
        model.dismissBulk(message)
    }
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { SectionTitle("稍后再看", app::back) }
                if (items.isNotEmpty() || choosing) {
                    TextButton(enabled = !model.writing, onClick = {
                        if (choosing) closeSelection() else choosing = true
                    }, modifier = Modifier.padding(end = 12.dp)) { Text(if (choosing) "完成" else "管理") }
                }
            }
            if (choosing) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("已选 ${selection.size} 项", Modifier.weight(1f), color = Muted, fontSize = 13.sp)
                    TextButton(enabled = !model.writing && selection.isNotEmpty(), onClick = { confirm = true }) {
                        Text("移除")
                    }
                }
            }
            PullToRefreshBox(isRefreshing = model.refreshing, onRefresh = { model.load(refresh = true) }) {
                LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(items, key = WatchLaterEntry::aid) { entry ->
                        val checked = entry.aid in selected
                        WatchLaterRow(entry, Modifier.animateItem(), choosing, checked, model.pending(entry), toggle = {
                            selected = if (checked) selected.filter { it != entry.aid }.toLongArray() else selected + entry.aid
                        }, open = { entry.route?.let(app::open) }, remove = { model.remove(listOf(entry), false) })
                    }
                    if (model.loaded && !model.loading && items.isEmpty() && model.error == null) item {
                        EmptyNotice("暂无稍后再看的视频")
                    }
                    item { PageMore(model.loading, model.more, model.error) { model.load(more = model.loaded) } }
                }
            }
        }
        SnackbarHost(snackbars, Modifier.align(Alignment.BottomCenter))
    }
    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text("移除所选视频") },
        text = { Text("从稍后再看移除 ${selection.size} 个视频？") },
        confirmButton = { TextButton(enabled = selection.isNotEmpty(), onClick = {
            confirm = false
            model.remove(selection, true, ::closeSelection)
        }) { Text("移除") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("取消") } },
    )
}

@Composable private fun WatchLaterRow(
    entry: WatchLaterEntry, modifier: Modifier, choosing: Boolean, checked: Boolean,
    pending: Boolean, toggle: () -> Unit, open: () -> Unit, remove: () -> Unit,
) {
    val video = entry.video
    Row(
        modifier.fillMaxWidth().clickable(enabled = !pending && (choosing || video != null), onClick = if (choosing) toggle else open),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f)) {
            MediaSummaryLayout(116, thumbnail = {
                RemoteImage(video?.cover, null, it.clip(RoundedCornerShape(6.dp)))
            }) {
                Text(entry.title, maxLines = 3, overflow = TextOverflow.Ellipsis, fontSize = 14.sp)
                if (video == null) Text("视频不可播放", fontSize = 12.sp, color = Muted)
                else {
                    Text(video.owner.name, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 12.sp, color = Muted)
                    Text(when {
                        entry.progress == -1L -> "已看完"
                        entry.progress > 0 -> "看到 ${clock(entry.progress)} / ${clock(video.duration)}"
                        else -> clock(video.duration)
                    }, fontSize = 12.sp, color = Muted)
                }
            }
        }
        if (choosing) Checkbox(checked, onCheckedChange = { toggle() }, enabled = !pending)
        else IconButton(onClick = remove, enabled = !pending) {
            if (pending) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 1.5.dp)
            else Icon(Icons.Rounded.Close, "移出稍后再看", tint = Muted)
        }
    }
}

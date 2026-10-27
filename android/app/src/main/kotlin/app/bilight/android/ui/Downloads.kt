@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package app.bilight.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import app.bilight.android.core.*
import app.bilight.android.downloads.*
import app.bilight.android.playback.PlaybackModel

@Composable fun DownloadOptions(app: AppModel, model: PlaybackModel, close: () -> Unit) {
    val detail = model.detail ?: return
    val part = model.part ?: return
    val playback = model.playback ?: return
    val context = LocalContext.current
    var selected by remember { mutableIntStateOf(playback.quality) }
    val requestNotification = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { /* A denial does not block app-private downloads. */ }
    ModalBottomSheet(onDismissRequest = close,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),dragHandle=null) {
        Column(Modifier.weight(1f,fill=false).fillMaxWidth().verticalScroll(rememberScrollState()).padding(start=20.dp,top=20.dp,end=20.dp).navigationBarsPadding()) {
            Text("下载视频", style = MaterialTheme.typography.titleLarge)
            Text("P${part.page} ${part.title}", Modifier.padding(top = 12.dp), fontSize = 14.sp, color = Muted)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                playback.qualities.forEach { quality -> FilterChip(selected == quality.id, onClick = { selected = quality.id }, label = { Text(quality.label) }) }
            }
            Button(onClick = {
                if (!app.requireLogin()) { close(); return@Button }
                playback.qualities.firstOrNull { it.id == selected }?.let { app.downloads.enqueue(detail, part, it) }
                if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) requestNotification.launch(Manifest.permission.POST_NOTIFICATIONS)
                close()
            }, modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp), enabled = app.downloads.ready) { Text("开始下载") }
        }
    }
}

@Composable fun DownloadsScreen(app: AppModel) {
    val store = app.downloads
    val context = LocalContext.current
    var deleting by remember { mutableStateOf<DownloadRecord?>(null) }
    var exportError by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        SectionTitle("我的下载", app::back)
        ErrorNotice(store.error,store::retry); ErrorNotice(exportError)
        if (app.user == null) { TextButton(onClick = { app.showLogin = true }) { Text("登录B站") }; return }
        if (!store.ready) { if (store.error==null) Loading(); return }
        if (store.items.isEmpty()) Text("暂无下载", Modifier.padding(24.dp), color = Muted)
        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            items(store.items, key = { it.id }) { item ->
                Column {
                    Box(Modifier.fillMaxWidth().clickable(enabled = item.state == DownloadState.COMPLETED) {
                        if (store.file(item) != null) app.open(Route.Watch(item.video.bvid, item.part.page, downloadId = item.id)) else exportError = "离线文件已丢失，请重新下载。"
                    }) {
                        MediaSummaryLayout(110,thumbnail={ RemoteImage(item.video.cover,item.video.title,it) }) {
                            Text(item.video.title, maxLines = 2, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, fontSize = 14.sp)
                            Text("P${item.part.page} · ${item.label} · ${item.state.label}", color = Muted, fontSize = 12.sp)
                            item.error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
                        }
                    }
                    if (item.state.active && item.total > 0) LinearProgressIndicator(progress = { (item.received.toFloat() / item.total).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().padding(top = 10.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                        if (item.state.active) IconButton(onClick = { store.pause(item.id) }) { Icon(Icons.Rounded.Pause, "暂停下载") }
                        if (item.state in listOf(DownloadState.PAUSED, DownloadState.FAILED)) {
                            IconButton(onClick = { store.resume(item.id) }) { Icon(Icons.Rounded.PlayArrow, "继续下载") }
                            IconButton(onClick = { store.resume(item.id, true) }) { Icon(Icons.Rounded.RestartAlt, "重新下载") }
                        }
                        if (item.state == DownloadState.COMPLETED) IconButton(onClick = {
                            try {
                                val file = store.file(item) ?: invalid("离线文件已丢失。")
                                val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                                val share = Intent(Intent.ACTION_SEND).setType("video/mp4").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                context.startActivity(Intent.createChooser(share, "导出视频"))
                            } catch (_: Exception) { exportError = "无法导出文件，请确认视频已经下载完成。" }
                        }) { Icon(Icons.Rounded.IosShare, "导出文件") }
                        IconButton(onClick = { deleting = item }) { Icon(Icons.Rounded.DeleteOutline, "删除下载") }
                    }
                }
            }
        }
    }
    deleting?.let { item -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text("删除下载？") }, text = { Text(item.video.title) }, confirmButton = { TextButton(onClick = { store.remove(item.id); deleting = null }) { Text("删除") } }, dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } }) }
}

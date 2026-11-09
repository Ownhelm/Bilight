package app.bilight.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.IosShare
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.net.URLEncoder

internal fun videoShareUrl(bvid: String, page: Int): String {
    val id = URLEncoder.encode(bvid, "UTF-8").replace("+", "%20")
    return "https://www.bilibili.com/video/$id/" + if (page > 1) "?p=$page" else ""
}

internal fun videoShareIntent(title: String, url: String): Intent = Intent(Intent.ACTION_SEND)
    .setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, title).putExtra(Intent.EXTRA_TEXT, "$title\n$url")

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun VideoShareSheet(bvid: String, title: String, page: Int, close: () -> Unit) {
    val context = LocalContext.current
    val url = remember(bvid, page) { videoShareUrl(bvid, page) }
    var error by remember(url) { mutableStateOf<String?>(null) }
    var manualCopy by remember(url) { mutableStateOf(false) }
    val dark = LocalDarkAppearance.current
    val ink = if (dark) Muted else Color(0xff61666d)
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        shape = RoundedCornerShape(topStart = 12.dp, topEnd = 12.dp), containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 0.dp, scrimColor = Color.Black.copy(alpha = .32f), dragHandle = null) {
        Column(Modifier.fillMaxWidth().testTag("video-share-sheet").verticalScroll(rememberScrollState())) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 20.dp, bottom = 16.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ShareOption("复制链接", Icons.Outlined.Link, Modifier.weight(1f), rotation = -45f) {
                    runCatching { (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("B站原视频链接", url)) }
                        .onSuccess { close(); Toast.makeText(context, "链接已复制", Toast.LENGTH_SHORT).show() }
                        .onFailure { error = "无法自动复制，请手动复制下方链接。"; manualCopy = true }
                }
                ShareOption("系统分享", Icons.Outlined.IosShare, Modifier.weight(1f)) {
                    runCatching { context.startActivity(Intent.createChooser(videoShareIntent(title, url), "分享视频")) }
                        .onSuccess { close() }
                        .onFailure { error = "系统分享未能打开，请复制链接。" }
                }
            }
            error?.let { Text(it, Modifier.padding(horizontal = 20.dp).padding(bottom = 14.dp), fontSize = 12.sp, color = Pink) }
            if (manualCopy) SelectionContainer { Text(url, Modifier.padding(horizontal = 20.dp).padding(bottom = 14.dp), fontSize = 12.sp, color = ink) }
            HorizontalDivider(thickness = 6.dp, color = if (dark) Soft else Color(0xfff6f7f8))
            TextButton(onClick = close, modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp), shape = RoundedCornerShape(0.dp)) {
                Text("取消", fontSize = 14.sp, color = if (dark) MaterialTheme.colorScheme.onSurface else Color(0xff18191c))
            }
        }
    }
}

@Composable private fun ShareOption(label: String, icon: ImageVector, modifier: Modifier, rotation: Float = 0f, action: () -> Unit) {
    val dark = LocalDarkAppearance.current
    Column(modifier.heightIn(min = 72.dp).clickable(role = Role.Button, onClick = action)
        .semantics(mergeDescendants = true) { contentDescription = label }, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(44.dp).background(if (dark) Soft else Color(0xfff5f5f5), CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = if (dark) Muted else Color(0xff61666d), modifier = Modifier.size(22.dp).rotate(rotation))
        }
        Spacer(Modifier.height(8.dp))
        Text(label, fontSize = 11.sp, color = if (dark) Muted else Color(0xff9499a0), textAlign = TextAlign.Center)
    }
}

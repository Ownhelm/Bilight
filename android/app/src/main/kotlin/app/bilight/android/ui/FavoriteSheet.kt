@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package app.bilight.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.bilight.android.core.Folder

/** The folder list scrolls while the sheet actions stay visible. */
@Composable internal fun FavoriteSheet(
    folders: List<Folder>?, selected: Set<Long>, error: String?, creating: Boolean,
    onSelection: (Set<Long>) -> Unit,
    close: () -> Unit, confirm: () -> Unit, create: (String) -> Unit,
    canConfirm: Boolean = true,
    retry: (() -> Unit)? = null,
) {
    val original=folders.orEmpty().filter { it.selected }.map { it.id }.toSet()
    var showCreateDialog by remember { mutableStateOf(false) }
    var title by remember { mutableStateOf("") }
    val canCreate=canConfirm && folders!=null && folders.size<100 && !creating
    ModalBottomSheet(
        onDismissRequest=close,
        sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),
        containerColor=MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(.75f)) {
            Text("收藏到（${selected.size}）",Modifier.padding(horizontal=20.dp,vertical=8.dp),
                style=MaterialTheme.typography.titleLarge,fontWeight=FontWeight.SemiBold)
            Column(Modifier.fillMaxWidth().weight(1f).testTag("favorite-scroll")
                .verticalScroll(rememberScrollState()).padding(horizontal=20.dp)) {
                ErrorNotice(error, if (folders==null) retry else null)
                if (folders==null && error==null) Loading("正在读取收藏夹")
                if (folders!=null) {
                    TextButton(onClick={ onSelection(emptySet()) },enabled=selected.isNotEmpty() && !creating) { Text("取消全部") }
                    if (folders.isEmpty()) Text("暂无收藏夹，可在下方新建",style=MaterialTheme.typography.bodyMedium,color=Muted)
                    folders.sortedByDescending { it.selected }.forEach { folder ->
                        val checked=folder.id in selected
                        val enabled=!creating && (checked || folder.selected || folder.count<folder.capacity)
                        Row(Modifier.fillMaxWidth().heightIn(min=64.dp)
                            .toggleable(value=checked,enabled=enabled,role=Role.Checkbox,
                                onValueChange={ onSelection(if (it) selected+folder.id else selected-folder.id) })
                            .padding(vertical=8.dp),verticalAlignment=Alignment.CenterVertically) {
                            Column(Modifier.weight(1f).padding(end=12.dp)) {
                                Text(folder.title,style=MaterialTheme.typography.bodyLarge)
                                Text("${folder.count}/${folder.capacity}${if (folder.private) " · 私密" else " · 公开"}${if (folder.count>=folder.capacity) " · 已满" else ""}",
                                    style=MaterialTheme.typography.bodySmall,color=Muted)
                            }
                            Checkbox(checked=checked,onCheckedChange=null,enabled=enabled)
                        }
                        HorizontalDivider(color=MaterialTheme.colorScheme.outlineVariant)
                    }
                    TextButton(
                        onClick={ title=""; showCreateDialog=true },
                        enabled=canCreate,
                        modifier=Modifier.padding(top=8.dp).heightIn(min=48.dp),
                        contentPadding=PaddingValues(end=12.dp,top=8.dp,bottom=8.dp),
                        colors=ButtonDefaults.textButtonColors(contentColor=Pink),
                    ) {
                        if (creating) CircularProgressIndicator(Modifier.size(20.dp),strokeWidth=2.dp)
                        else Icon(Icons.Rounded.Add,contentDescription=null,modifier=Modifier.size(20.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("新建收藏夹")
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
            HorizontalDivider()
            Row(Modifier.fillMaxWidth().padding(horizontal=20.dp,vertical=12.dp),
                horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick=close,modifier=Modifier.weight(1f).heightIn(min=48.dp)) { Text("取消") }
                Button(onClick=confirm,enabled=canConfirm && folders!=null && selected!=original && !creating,
                    modifier=Modifier.weight(1f).heightIn(min=48.dp)) { Text("确定") }
            }
        }
        if (showCreateDialog) {
            AlertDialog(
                onDismissRequest={ showCreateDialog=false },
                title={ Text("新建收藏夹") },
                text={
                    val focus=remember { FocusRequester() }
                    OutlinedTextField(
                        value=title, onValueChange={ title=it },
                        label={ Text("1–20 个字") }, singleLine=true,
                        modifier=Modifier.fillMaxWidth().focusRequester(focus),
                    )
                    LaunchedEffect(Unit) { focus.requestFocus() }
                },
                dismissButton={ TextButton(onClick={ showCreateDialog=false }) { Text("取消") } },
                confirmButton={
                    TextButton(
                        onClick={ showCreateDialog=false; create(title) },
                        enabled=canCreate && title.isNotBlank() && title.codePointCount(0,title.length)<=20,
                    ) { Text("创建") }
                },
            )
        }
    }
}

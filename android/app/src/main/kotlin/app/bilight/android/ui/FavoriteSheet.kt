@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package app.bilight.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.bilight.android.core.Folder

/** One scroll owner for folders and creation; actions stay above the system/IME insets. */
@Composable internal fun FavoriteSheet(
    folders: List<Folder>?, selected: Set<Long>, error: String?, title: String, creating: Boolean,
    onSelection: (Set<Long>) -> Unit, onTitle: (String) -> Unit,
    close: () -> Unit, confirm: () -> Unit, create: () -> Unit,
    canConfirm: Boolean = true,
) {
    val original=folders.orEmpty().filter { it.selected }.map { it.id }.toSet()
    ModalBottomSheet(
        onDismissRequest=close,
        sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),
        containerColor=MaterialTheme.colorScheme.surface,
    ) {
        Column(Modifier.fillMaxWidth().weight(1f,fill=false)) {
            Text("收藏到（${selected.size}）",Modifier.padding(horizontal=20.dp,vertical=8.dp),
                style=MaterialTheme.typography.titleLarge,fontWeight=FontWeight.SemiBold)
            Column(Modifier.fillMaxWidth().weight(1f,fill=false).testTag("favorite-scroll")
                .verticalScroll(rememberScrollState()).padding(horizontal=20.dp)) {
                ErrorNotice(error)
                if (folders==null && error==null) Loading()
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
                    Spacer(Modifier.height(16.dp))
                    OutlinedTextField(value=title,onValueChange=onTitle,label={ Text("新建公开收藏夹") },
                        singleLine=true,enabled=!creating,modifier=Modifier.fillMaxWidth(),
                        supportingText={ Text("最多20个字，新建后仍需点击确定") })
                    TextButton(onClick=create,enabled=title.isNotBlank() && title.codePointCount(0,title.length)<=20 && folders.size<100 && !creating) {
                        Text(if (creating) "正在新建" else "新建并勾选")
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
    }
}

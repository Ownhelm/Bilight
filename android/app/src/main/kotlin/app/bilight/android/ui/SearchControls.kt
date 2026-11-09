package app.bilight.android.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.bilight.android.core.AppModel
import app.bilight.android.core.VideoSearchOrder

internal val SearchCapsuleColor = Color(0xfff7f9fb)
private val SearchMuted: Color
    @Composable get() = if (LocalDarkAppearance.current) Muted else Color(0xff7a8291)

@Composable internal fun CapsuleSearchField(
    value: String, onValueChange: (String) -> Unit, placeholder: String, clearLabel: String,
    onClear: () -> Unit, onSearch: () -> Unit, modifier: Modifier = Modifier, showSubmit: Boolean = false,
) {
    val selection = TextSelectionColors(handleColor = SearchMuted, backgroundColor = SearchMuted.copy(alpha = .20f))
    CompositionLocalProvider(LocalTextSelectionColors provides selection) {
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = modifier.fillMaxWidth(),
            singleLine = true,
            textStyle = LocalTextStyle.current.copy(color = MaterialTheme.colorScheme.onSurface, fontSize = 14.sp),
            cursorBrush = SolidColor(SearchMuted),
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Search,
            ),
            keyboardActions = KeyboardActions(onSearch = { onSearch() }),
            decorationBox = { innerField ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(CircleShape)
                        .background(if (LocalDarkAppearance.current) Soft else SearchCapsuleColor)
                        .padding(start = 16.dp, end = if (showSubmit || value.isNotEmpty()) 6.dp else 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Rounded.Search, null, Modifier.size(20.dp), tint = SearchMuted)
                    Spacer(Modifier.width(10.dp))
                    Box(Modifier.weight(1f), propagateMinConstraints = true) {
                        if (value.isEmpty()) Text(placeholder, color = SearchMuted, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        innerField()
                    }
                    if (value.isNotEmpty()) {
                        IconButton(onClick = onClear, modifier = Modifier.size(44.dp)) {
                            Icon(Icons.Rounded.Cancel, clearLabel, Modifier.size(18.dp), tint = SearchMuted.copy(alpha = .65f))
                        }
                    }
                    if (showSubmit) {
                        val enabled = value.isNotBlank()
                        Box(
                            Modifier.testTag("submit-search").heightIn(min = 44.dp)
                                .clickable(enabled = enabled, role = Role.Button, onClick = onSearch)
                                .padding(horizontal = 10.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text("搜索", color = if (enabled) Pink else Pink.copy(alpha = .55f), fontSize = 14.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            },
        )
    }
}

@Composable internal fun SearchResultsBar(app: AppModel, modifier: Modifier = Modifier) {
    val focus = LocalFocusManager.current
    Box(modifier.fillMaxWidth()) {
        HorizontalDivider(Modifier.align(Alignment.BottomCenter), thickness = 0.5.dp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .06f))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            SearchTab("视频", !app.searchUsers) { focus.clearFocus(); app.chooseSearchType(false) }
            Spacer(Modifier.width(18.dp))
            SearchTab("UP 主", app.searchUsers) { focus.clearFocus(); app.chooseSearchType(true) }
            Spacer(Modifier.weight(1f))
            if (!app.searchUsers) VideoSearchFilter(app)
        }
    }
}

@Composable private fun SearchTab(label: String, isSelected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.sizeIn(minWidth = 44.dp, minHeight = 44.dp)
            .selectable(isSelected, role = Role.Tab, indication = null, interactionSource = null, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = if (isSelected) Pink else SearchMuted, fontSize = 15.sp, fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal)
        if (isSelected) Box(Modifier.align(Alignment.BottomCenter).size(23.dp, 3.dp).background(Pink, CircleShape))
    }
}

internal const val TitleFilterLabel = "仅标题匹配"

@Composable private fun VideoSearchFilter(app: AppModel) {
    val focus = LocalFocusManager.current
    var expanded by remember { mutableStateOf(false) }
    val order = app.videoSearchOrder
    val titleOnly = app.searchTitleOnly
    val active = titleOnly || order != VideoSearchOrder.RELEVANCE
    val label = if (titleOnly) TitleFilterLabel else if (active) order.label else "筛选"
    val color = if (active) Pink else SearchMuted
    Box {
        Row(
            Modifier.sizeIn(minWidth = 44.dp, minHeight = 44.dp).testTag("video-search-filter")
                .clickable(role = Role.Button, indication = null, interactionSource = null) {
                    focus.clearFocus()
                    expanded = true
                }.semantics {
                    contentDescription = "搜索筛选"
                    stateDescription = if (titleOnly) "${order.label}，$TitleFilterLabel" else order.label
                },
            horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Rounded.Tune, null, Modifier.size(17.dp), tint = color)
            if (LocalDensity.current.fontScale < 1.6f) Text(label, color = color, fontSize = 14.sp)
            Icon(Icons.Rounded.ExpandMore, null, Modifier.size(15.dp), tint = color)
        }
        DropdownMenu(
            expanded = expanded, onDismissRequest = { expanded = false }, modifier = Modifier.width(204.dp),
            shape = RoundedCornerShape(12.dp), containerColor = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 0.dp,
            shadowElevation = 6.dp, border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = .12f)),
        ) {
            VideoSearchOrder.entries.forEach { choice ->
                FilterRow(choice.label, order == choice, SearchMuted) {
                    expanded = false
                    app.chooseVideoSearchOrder(choice)
                }
            }
            HorizontalDivider(Modifier.padding(horizontal = 12.dp))
            FilterRow(TitleFilterLabel, titleOnly, Pink, description = "只保留标题包含所有搜索词的视频") {
                expanded = false
                app.toggleSearchTitleOnly()
            }
        }
    }
}

@Composable private fun FilterRow(label: String, isSelected: Boolean, checkColor: Color, description: String? = null, onClick: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(role = Role.Button, onClick = onClick)
            .semantics { selected = isSelected }.padding(horizontal = 12.dp, vertical = if (description == null) 0.dp else 8.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, fontSize = 14.sp)
            Spacer(Modifier.weight(1f))
            if (isSelected) Icon(Icons.Rounded.Check, null, Modifier.size(17.dp), tint = checkColor)
        }
        if (description != null) {
            Spacer(Modifier.height(3.dp))
            Text(description, color = SearchMuted, fontSize = 11.sp, lineHeight = 15.sp)
        }
    }
}

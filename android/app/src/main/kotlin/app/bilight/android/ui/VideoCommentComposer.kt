@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package app.bilight.android.ui

import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import app.bilight.android.core.AppModel
import app.bilight.android.core.CommentTarget
import app.bilight.android.core.User
import app.bilight.android.playback.CommentsModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first

internal data class CommentDraft(val field: TextFieldValue = TextFieldValue(), val users: List<User> = emptyList())

internal class VideoCommentComposerState {
    private val drafts = mutableStateMapOf<String,CommentDraft>()
    var visible by mutableStateOf(false); private set
    var target by mutableStateOf<CommentTarget?>(null); private set
    private val draftKey get() = target?.parent?.id ?: "root"
    var draft: CommentDraft
        get() = drafts[draftKey] ?: CommentDraft()
        set(value) { drafts[draftKey] = value }
    fun open(target: CommentTarget?) { this.target = target; visible = true }
    fun close() { visible = false }
    fun sent() { drafts.remove(draftKey); close() }
}

internal data class CommentMentionQuery(val start: Int, val end: Int, val keyword: String)

private val commentMentionMarkers = charArrayOf('@', '＠')
private const val mentionTerminators = "@＠，。！？；：、"

internal fun mentionQuery(field: TextFieldValue): CommentMentionQuery? {
    if (!field.selection.collapsed || field.composition != null) return null
    val caret = field.selection.start
    val start = field.text.lastIndexOfAny(commentMentionMarkers, caret - 1)
    if (start < 0) return null
    val keyword = field.text.substring(start+1,caret)
    if (keyword.length > 32 || keyword.any { it.isWhitespace() || it in mentionTerminators }) return null
    val previous = field.text.getOrNull(start-1)
    if (previous != null && previous.code < 128 && (previous.isLetterOrDigit() || previous in "._%+-")) return null
    return CommentMentionQuery(start,caret,keyword)
}

@Composable internal fun CommentComposerEntry(app: AppModel,onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=4.dp),horizontalArrangement=Arrangement.spacedBy(10.dp),verticalAlignment=Alignment.CenterVertically) {
        app.user?.let { Avatar(it,32) }
        Surface(shape=RoundedCornerShape(8.dp),color=MaterialTheme.colorScheme.surfaceContainerHighest,
            modifier=Modifier.weight(1f).heightIn(min=44.dp).clip(RoundedCornerShape(8.dp)).clickable(onClick=onClick).testTag("video-comment-open")) {
            Box(Modifier.padding(horizontal=12.dp),contentAlignment=Alignment.CenterStart) {
                Text(if (app.user==null) "登录后发表评论" else "说点什么吧…",color=Muted,fontSize=13.sp)
            }
        }
    }
}

internal fun LazyListScope.commentItems(app: AppModel, model: CommentsModel, composer: VideoCommentComposerState,
    oid: String, type: Int, showPagination: Boolean = true) {
    if (model.canInteractWithComments()) item {
        CommentComposerEntry(app) { if (!model.commentSending && app.requireLogin()) composer.open(null) }
    }
    items(model.comments,key={ it.id }) { comment ->
        key(model.commentRefreshRevision) {
            CommentRow(app,comment,oid,type,interaction=model,onReply={ target ->
                if (!model.commentSending && app.requireLogin()) composer.open(target)
            })
        }
    }
    if (showPagination) item {
        PageMore(model.commentsBusy,model.commentsMore,model.commentsError) {
            if (model.commentSendNeedsRefresh) model.refreshComments() else model.loadComments()
        }
        if (!model.commentsBusy && !model.commentsMore && model.commentsError==null && model.comments.isEmpty()) EmptyNotice("暂时没有评论")
    }
}

@Composable internal fun CommentComposerSheet(model: CommentsModel,composer: VideoCommentComposerState) {
    val draft = composer.draft
    val tooLong = draft.field.text.codePointCount(0,draft.field.text.length)>1000
    val query = mentionQuery(draft.field)
    var suggestions by remember(query?.keyword) { mutableStateOf(emptyList<User>()) }
    var suggestionError by remember(query?.keyword) { mutableStateOf<String?>(null) }
    var searching by remember(query?.keyword) { mutableStateOf(query != null) }
    val candidates = query?.let { active ->
        val participants = composer.target?.let { listOf(it.parent.user,it.root.user) }.orEmpty()
            .filter { it.mid>0 && it.name.isNotBlank() && it.name.contains(active.keyword,ignoreCase=true) }
        (suggestions+participants).distinctBy { it.mid }.take(5)
    }.orEmpty()
    val focus = remember { FocusRequester() }
    val title = composer.target?.let { "回复 ${it.parent.user.name}" } ?: "发表评论"
    LaunchedEffect(query?.keyword) {
        val keyword = query?.keyword ?: return@LaunchedEffect
        try {
            if (keyword.isNotEmpty()) delay(250)
            suggestions = model.searchCommentMentionUsers(keyword)
        }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { suggestionError = e.message ?: "暂时无法查找用户。" }
        finally { searching = false }
    }
    CommentComposerPanel(title, focus, sending=model.commentSending, onDismiss=composer::close) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(start=16.dp,end=16.dp,bottom=16.dp),
            verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment=Alignment.CenterVertically) {
                Text(title,Modifier.weight(1f),
                    maxLines=1,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.titleMedium)
                TextButton(onClick=composer::close,enabled=!model.commentSending) { Text("取消") }
            }
            // Keep Send in the sheet footer even when the keyboard reduces the available height.
            Column(Modifier.weight(1f,fill=false).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                val editorColor = MaterialTheme.colorScheme.surfaceContainerHighest
                TextField(value=draft.field,onValueChange={ changed ->
                    val selected = draft.users.filter { Regex("@${Regex.escape(it.name)}(?=\\s|$)").containsMatchIn(changed.text) }
                    composer.draft=CommentDraft(changed,selected)
                },
                    modifier=Modifier.fillMaxWidth().focusRequester(focus).testTag("video-comment-text"),
                    enabled=!model.commentSending,minLines=if (query==null) 3 else 1,maxLines=if (query==null) 6 else 2,
                    placeholder={ Text("友善发言，分享你的想法") },
                    isError=tooLong,
                    shape=RoundedCornerShape(8.dp), colors=TextFieldDefaults.colors(
                        focusedIndicatorColor=Color.Transparent, unfocusedIndicatorColor=Color.Transparent,
                        disabledIndicatorColor=Color.Transparent, errorIndicatorColor=Color.Transparent,
                        focusedContainerColor=editorColor, unfocusedContainerColor=editorColor,
                        disabledContainerColor=editorColor, errorContainerColor=editorColor,
                    ))
                if (query!=null) {
                    when {
                        suggestionError!=null -> Text(checkNotNull(suggestionError),fontSize=12.sp,color=Pink)
                        candidates.isEmpty() && searching -> Text("正在查找用户…",fontSize=12.sp,color=Muted)
                        candidates.isEmpty() && query.keyword.isEmpty() -> Text("输入用户名搜索",fontSize=12.sp,color=Muted)
                        candidates.isEmpty() -> Text("没有查到匹配的用户",fontSize=12.sp,color=Muted)
                    }
                    candidates.forEach { user ->
                        Row(Modifier.fillMaxWidth().heightIn(min=44.dp).clickable(enabled=!model.commentSending) {
                            val token = "@${user.name} "
                            val end = query.end + if (draft.field.text.getOrNull(query.end)==' ') 1 else 0
                            val text = draft.field.text.replaceRange(query.start,end,token)
                            composer.draft=CommentDraft(TextFieldValue(text,TextRange(query.start+token.length)),(draft.users+user).distinctBy { it.mid })
                        }.padding(horizontal=6.dp),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically) {
                            Avatar(user,26)
                            Text(user.name,Modifier.weight(1f),maxLines=1,overflow=TextOverflow.Ellipsis)
                            Text("UID ${user.mid}",fontSize=11.sp,color=Muted)
                        }
                    }
                }
            }
            if (tooLong) Text("评论不能超过 1000 字",color=Pink,fontSize=13.sp)
            model.commentSendError?.let { Text(it,color=Pink,fontSize=13.sp) }
            Row(Modifier.fillMaxWidth(), horizontalArrangement=Arrangement.End, verticalAlignment=Alignment.CenterVertically) {
                if (model.commentSendNeedsRefresh) {
                    Button(onClick={ composer.close(); model.refreshComments() },enabled=model.canInteractWithComments() && !model.commentsBusy) {
                        Text("刷新评论")
                    }
                } else {
                    Button(onClick={ model.sendComment(draft.field.text,draft.users,composer.target,composer::sent) },
                        enabled=model.canInteractWithComments() && !model.commentSending && !tooLong && draft.field.text.isNotBlank(),
                        modifier=Modifier.testTag("video-comment-send").semantics {
                            contentDescription=if (model.commentSending) "正在发送评论" else "发送评论"
                        }) { Text(if (model.commentSending) "发送中…" else "发送") }
                }
            }
        }
    }
}

@Composable private fun CommentComposerPanel(title: String, focus: FocusRequester, sending: Boolean,
    onDismiss: () -> Unit, content: @Composable () -> Unit) {
    Dialog(onDismissRequest={ if (!sending) onDismiss() }, properties=DialogProperties(
        dismissOnClickOutside=false, usePlatformDefaultWidth=false, decorFitsSystemWindows=false,
    )) {
        val window = (LocalView.current.parent as DialogWindowProvider).window
        val windowInfo = LocalWindowInfo.current
        var openingFraction by remember { mutableFloatStateOf(0f) }
        var imeAnimating by remember { mutableStateOf(false) }
        DisposableEffect(window) {
            window.setWindowAnimations(0)
            window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            val decor = window.decorView
            val ime = WindowInsetsCompat.Type.ime()
            // A newly focused dialog can receive the final inset before the IME starts drawing.
            // Reveal the panel from the actual animation frames, not the reported final position.
            ViewCompat.setWindowInsetsAnimationCallback(decor, object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                private var active: WindowInsetsAnimationCompat? = null
                private var target = 0

                override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                    if (animation.typeMask and ime != 0 && openingFraction<1f) {
                        active = animation
                        target = 0
                        imeAnimating = true
                    }
                }

                override fun onStart(animation: WindowInsetsAnimationCompat, bounds: WindowInsetsAnimationCompat.BoundsCompat): WindowInsetsAnimationCompat.BoundsCompat {
                    if (active===animation) target = bounds.upperBound.bottom
                    return bounds
                }

                override fun onProgress(insets: WindowInsetsCompat, runningAnimations: List<WindowInsetsAnimationCompat>): WindowInsetsCompat {
                    if (target>0 && insets.isVisible(ime) && runningAnimations.any { it===active }) {
                        val progress = (insets.getInsets(ime).bottom.toFloat()/target).coerceIn(0f,1f)
                        openingFraction = maxOf(openingFraction,progress)
                    }
                    return insets
                }

                override fun onEnd(animation: WindowInsetsAnimationCompat) {
                    if (active!==animation) return
                    active = null
                    imeAnimating = false
                    if (openingFraction>0f && ViewCompat.getRootWindowInsets(decor)?.isVisible(ime)==true) openingFraction = 1f
                }
            })
            onDispose { ViewCompat.setWindowInsetsAnimationCallback(decor,null) }
        }
        LaunchedEffect(windowInfo) {
            snapshotFlow { windowInfo.isWindowFocused }.first { it }
            focus.requestFocus()
            // Hardware and floating keyboards may not animate a bottom inset.
            delay(500)
            snapshotFlow { !imeAnimating }.first { it }
            openingFraction = 1f
        }
        Box(Modifier.fillMaxSize()) {
            Box(Modifier.matchParentSize().graphicsLayer { alpha=openingFraction }
                .background(BottomSheetDefaults.ScrimColor)
                .clickable(enabled=!sending, interactionSource=null, indication=null, onClick=onDismiss)
                .semantics { contentDescription="关闭评论窗口" })
            Box(Modifier.fillMaxSize().statusBarsPadding().imePadding(),
                contentAlignment=Alignment.BottomCenter) {
                Surface(Modifier.widthIn(max=640.dp).fillMaxWidth().graphicsLayer { alpha=openingFraction }
                    .semantics { paneTitle=title }, shape=BottomSheetDefaults.ExpandedShape,
                    color=BottomSheetDefaults.ContainerColor, content=content)
            }
        }
    }
}

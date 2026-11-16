package app.bilight.android.playback

import androidx.compose.runtime.*
import app.bilight.android.core.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

/** Comment state shared by video and dynamic threads, independently of playback. */
internal class CommentsModel(
    private val app: AppModel,
    private val scope: CoroutineScope,
    private val subject: () -> CommentSubject?,
    private val available: () -> Boolean = { true },
    private val writable: () -> Boolean = { true },
) {
    private val version = app.http.generation
    val comments = mutableStateListOf<Comment>()
    var commentsBusy by mutableStateOf(false); private set
    var commentsMore by mutableStateOf(true); private set
    var commentsError by mutableStateOf<String?>(null); private set
    val postedReplies = mutableStateMapOf<String,List<Comment>>()
    val commentLikeErrors = mutableStateMapOf<String,String>()
    var commentSending by mutableStateOf(false); private set
    var commentSendError by mutableStateOf<String?>(null); private set
    var commentSendNeedsRefresh by mutableStateOf(false); private set
    var commentRefreshRevision by mutableIntStateOf(0); private set
    private var commentCursor: String? = null

    fun loadComments() = readComments(refresh=false)
    fun refreshComments() = readComments(refresh=true)
    private fun readComments(refresh: Boolean) {
        val target=subject() ?: return
        if (!available() || commentsBusy || (!refresh && !commentsMore)) return
        val likeVersion=app.commentLikes.revision
        val firstPage=refresh || commentCursor==null
        commentsBusy=true; commentsError=null
        scope.launch {
            try {
                app.http.check(version)
                val page=app.repository.comments(target.oid,target.type,cursor=if (refresh) null else commentCursor)
                ensureActive(); app.http.check(version)
                if (firstPage) app.commentLikes.forgetFromRead(likeVersion) { it.first==target.oid && it.second==target.type }
                if (refresh) {
                    comments.clear()
                    commentRefreshRevision++
                    commentLikeErrors.clear()
                    commentSendError=null; commentSendNeedsRefresh=false
                }
                val known=comments.map { it.id }.toHashSet()
                comments.addAll(page.items.filter { known.add(it.id) })
                commentsMore=page.more; commentCursor=page.cursor
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (version==app.http.generation) commentsError=e.message }
            finally { commentsBusy=false }
        }
    }
    fun canInteractWithComments(): Boolean = available() && writable() && subject() != null
    fun commentLike(comment: Comment): CommentLikeState {
        val initial=CommentLikeState(comment.liked,comment.likes)
        val thread=subject() ?: return initial
        val key=Triple(thread.oid,thread.type,comment.id)
        return app.commentLikes.pending[key] ?: app.commentLikes.confirmed[key] ?: initial
    }
    fun commentLikePending(comment: Comment): Boolean = subject()?.let {
        Triple(it.oid,it.type,comment.id) in app.commentLikes.pending
    } ?: false

    fun toggleCommentLike(comment: Comment) {
        val thread = subject() ?: return
        if (version!=app.http.generation || !canInteractWithComments() || !app.requireLogin()) return
        val key=Triple(thread.oid,thread.type,comment.id)
        commentLikeErrors.remove(comment.id)
        app.commentLikes.toggle(key,CommentLikeState(comment.liked,comment.likes),onError={
            commentLikeErrors[comment.id] = it.message ?: "评论点赞失败，请重试。"
        }) { target,generation ->
            app.repository.setCommentLike(thread,comment.id,target,expectedGeneration=generation)
        }
    }

    suspend fun searchCommentMentionUsers(query: String): List<User> {
        app.http.check(version)
        val users = app.repository.commentMentionUsers(query)
        app.http.check(version)
        return users
    }

    fun sendComment(message: String, mentions: List<User>, target: CommentTarget?, onSent: () -> Unit) {
        val thread = subject() ?: return
        if (!canInteractWithComments() || commentSending || commentSendNeedsRefresh || !app.requireLogin()) return
        commentSending = true
        commentSendError = null
        scope.launch {
            try {
                app.http.check(version)
                val posted = app.repository.postComment(thread,message,mentions,target)
                ensureActive(); app.http.check(version)
                if (target == null) {
                    comments.removeAll { it.id == posted.id }
                    comments.add(0,posted)
                } else {
                    val previous = postedReplies[target.root.id].orEmpty()
                    postedReplies[target.root.id] = (previous + posted).distinctBy { it.id }
                }
                onSent()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                if (version == app.http.generation) {
                    commentSendError = e.message ?: "评论发送失败，请重试。"
                    commentSendNeedsRefresh = (e as? BiliFailure)?.code=="COMMENT_UNCONFIRMED"
                }
            } finally { commentSending = false }
        }
    }
}

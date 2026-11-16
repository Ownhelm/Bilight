package app.bilight.android.core

import android.os.SystemClock
import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

private const val LIKE_DEBOUNCE_MS = 800L

/** Serializes writes per item while keeping the latest tap and its displayed count independent of older responses. */
internal class DebouncedLikes<Key>(private val scope: CoroutineScope, private val generation: () -> Long) {
    val confirmed = mutableStateMapOf<Key,LikeState>()
    val pending = mutableStateMapOf<Key,LikeState>()
    private val jobs = mutableMapOf<Key,Job>()
    private val sendAt = mutableMapOf<Key,Long>()
    private val uncertain = mutableSetOf<Key>()
    private val changedAt = mutableMapOf<Key,Long>()
    var revision = 0L; private set

    fun acceptsRead(key: Key, readVersion: Long) = key !in pending && (changedAt[key] ?: 0L)<=readVersion

    fun forgetFromRead(readVersion: Long, matches: (Key) -> Boolean) {
        confirmed.keys.filter { matches(it) && acceptsRead(it,readVersion) }.forEach(confirmed::remove)
    }

    fun toggle(key: Key, initial: LikeState, onError: (Exception) -> Unit, write: suspend (Boolean,Long) -> LikeState) {
        val version = generation()
        val before = confirmed[key] ?: initial
        val visible = pending[key] ?: before
        val target = !visible.liked
        confirmed[key] = before
        changedAt[key] = ++revision
        pending[key] = LikeState(target,(visible.likes + if (target) 1L else -1L).coerceAtLeast(0))
        sendAt[key] = SystemClock.elapsedRealtime()+LIKE_DEBOUNCE_MS
        if (jobs[key]?.isActive==true) return
        jobs[key] = scope.launch {
            try {
                while (version==generation()) {
                    val deadline = sendAt[key] ?: break
                    val wait = deadline-SystemClock.elapsedRealtime()
                    if (wait>0) { delay(wait); continue }
                    val requested = pending[key]?.liked ?: break
                    if (key !in uncertain && requested==confirmed[key]?.liked) break
                    val after = try {
                        write(requested,version)
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) {
                        if (version!=generation()) break
                        if (isUncertain(failure)) uncertain.add(key)
                        if (pending[key]?.liked==requested) { onError(failure); break }
                        continue
                    }
                    ensureActive()
                    if (version!=generation()) break
                    uncertain.remove(key)
                    confirmed[key] = after
                    if (pending[key]?.liked==after.liked) break
                }
            } finally {
                if (jobs[key]===coroutineContext[Job]) {
                    changedAt[key] = ++revision
                    pending.remove(key); sendAt.remove(key); jobs.remove(key)
                }
            }
        }
    }

    fun clear() {
        jobs.values.toList().forEach(Job::cancel); jobs.clear()
        uncertain.clear(); sendAt.clear(); pending.clear(); confirmed.clear(); changedAt.clear(); revision=0
    }

    private fun isUncertain(failure: Exception) = when (val code = (failure as? BiliFailure)?.code) {
        null,"NETWORK","INVALID_RESPONSE","DYNAMIC_LIKE_UNCONFIRMED","COMMENT_LIKE_UNCONFIRMED","BUSY","INTERACTION_BUSY" -> true
        else -> code.toIntOrNull()?.let { it==0 || it in 500..599 || it in -599..-500 }==true
    }
}

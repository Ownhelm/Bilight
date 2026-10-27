package app.bilight.android.playback

import kotlinx.coroutines.*

class LikePress(
    private val scope: CoroutineScope,
    private val canHold: () -> Boolean,
    private val tap: () -> Unit,
    private val triple: () -> Unit,
    private val charge: (Boolean) -> Unit
) {
    private var job: Job? = null
    private var active=false
    private var consumed=false
    fun begin() {
        if (active) return
        active=true; consumed=false
        job=scope.launch {
            delay(500); consumed=true
            if (!canHold()) { cancel(); return@launch }
            charge(true); delay(1500)
            if (active) { active=false; job=null; charge(false); triple() }
        }
    }
    fun end() {
        val short=active && !consumed
        active=false; job?.cancel(); job=null; charge(false)
        if (short) tap()
    }
    fun cancel() { active=false; consumed=true; job?.cancel(); job=null; charge(false) }
}

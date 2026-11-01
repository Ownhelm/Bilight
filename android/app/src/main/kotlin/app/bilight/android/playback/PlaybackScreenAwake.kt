package app.bilight.android.playback

import android.view.View
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.media3.common.Player

/** Keep only the foreground video page awake, including brief playback buffering. */
internal class PlaybackScreenAwake(
    private val view: View,
    private val player: Player,
    private val lifecycle: Lifecycle,
) : Player.Listener, LifecycleEventObserver, AutoCloseable {
    private val previous = view.keepScreenOn
    private var closed = false

    init {
        player.addListener(this)
        lifecycle.addObserver(this)
        update()
    }

    override fun onEvents(player: Player, events: Player.Events) = update()
    override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
        if (event == Lifecycle.Event.ON_DESTROY) close() else update()
    }

    private fun update() {
        if (closed) return
        val state = player.playbackState
        val awake = previous || (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            && player.playWhenReady && (state == Player.STATE_READY || state == Player.STATE_BUFFERING)
            && player.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE
            && player.playerError == null)
        if (view.keepScreenOn != awake) view.keepScreenOn = awake
    }

    override fun close() {
        if (closed) return
        closed = true
        player.removeListener(this)
        lifecycle.removeObserver(this)
        view.keepScreenOn = previous
    }
}

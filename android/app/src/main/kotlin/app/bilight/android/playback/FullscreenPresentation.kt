package app.bilight.android.playback

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

fun fullscreenPresentation(requested: Boolean, portraitVideo: Boolean, landscapeWindow: Boolean, returning: Boolean, exiting: Boolean): Boolean =
    requested && (portraitVideo || landscapeWindow || returning) || exiting && landscapeWindow

internal enum class PlaybackPosture { UPRIGHT, LANDSCAPE_LEFT, LANDSCAPE_RIGHT }

/** Confirm one posture even when Android only reports changes in the measured angle. */
internal class PlaybackRotation(private val scope: CoroutineScope) {
    private var candidate: PlaybackPosture? = null
    private var confirmation: Job? = null
    var settled: PlaybackPosture? = null
        private set

    fun update(angle: Int, onSettled: (PlaybackPosture) -> Unit) {
        val next = when (angle) {
            in 75..105 -> PlaybackPosture.LANDSCAPE_LEFT
            in 255..285 -> PlaybackPosture.LANDSCAPE_RIGHT
            in 0..20, in 340..359 -> PlaybackPosture.UPRIGHT
            else -> null
        }
        if (next == candidate) return
        reset()
        candidate = next
        if (next != null) confirmation = scope.launch {
            delay(250)
            settled = next
            onSettled(next)
        }
    }

    fun reset() {
        confirmation?.cancel()
        confirmation = null
        candidate = null
        settled = null
    }
}

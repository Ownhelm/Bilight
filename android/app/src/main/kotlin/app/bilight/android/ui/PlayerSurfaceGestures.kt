package app.bilight.android.ui

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs

internal enum class PlayerDrag { SEEK, BRIGHTNESS, VOLUME, DISMISS }
internal enum class PlayerDragPhase { START, UPDATE, CANCEL_ZONE, COMMIT, CANCEL }

internal suspend fun PointerInputScope.detectSeekBarScrub(
    onPreview: (Float?) -> Unit,
    onCommit: (Float) -> Unit,
) = awaitEachGesture {
    // Material Slider also calls its drag-finished callback when a touch is canceled.
    // Consume physical touches before its detector while retaining Slider keyboard and accessibility actions.
    val down = awaitFirstDown(pass = PointerEventPass.Initial)
    fun fraction(x: Float) = (x / size.width.coerceAtLeast(1)).coerceIn(0f, 1f)
    down.consume()
    onPreview(fraction(down.position.x))
    var tracking = true
    try {
        while (true) {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            val change = event.changes.singleOrNull()?.takeIf { it.id == down.id && !it.isConsumed }
            if (tracking) {
                when {
                    change == null -> { tracking = false; onPreview(null) }
                    change.changedToUpIgnoreConsumed() -> onCommit(fraction(change.position.x))
                    else -> onPreview(fraction(change.position.x))
                }
            }
            event.changes.forEach { it.consume() }
            if (event.changes.none { it.pressed }) break
        }
    } finally { onPreview(null) }
}

internal suspend fun PointerInputScope.detectPlayerSurfaceGestures(
    fullscreen: Boolean,
    portrait: Boolean,
    locked: Boolean,
    onTap: () -> Unit,
    onDoubleTap: () -> Unit,
    onHold: (Boolean) -> Unit,
    onDrag: (PlayerDrag, PlayerDragPhase, Float) -> Unit,
    onDismiss: () -> Unit,
    onTwoFingerTap: () -> Unit,
    onPinch: (Float) -> Unit,
) = coroutineScope {
    var singleTap: Job? = null
    var tapUpTime = 0L
    var tapUpPosition = Offset.Zero

    awaitEachGesture {
        val down = awaitFirstDown()
        val width = size.width.coerceAtLeast(1).toFloat()
        val height = size.height.coerceAtLeast(1).toFloat()
        val slop = viewConfiguration.touchSlop
        val tapInterval = down.uptimeMillis - tapUpTime
        val doubleTap = !locked && singleTap?.isActive == true &&
            tapInterval in viewConfiguration.doubleTapMinTimeMillis..viewConfiguration.doubleTapTimeoutMillis &&
            (down.position - tapUpPosition).getDistance() <= 48.dp.toPx()
        if (doubleTap) singleTap?.cancel()

        var held = false
        val hold = if (locked) null else launch {
            delay(viewConfiguration.longPressTimeoutMillis)
            held = true
            onHold(true)
        }
        var direction: PlayerDrag? = null
        var committed = false
        var moved = false
        var pressedTogether = false
        var pinching = false
        var multiTouchMoved = false
        var pinchSpan = 0f
        var lastPinchSpan = 0f
        val startingPositions = mutableMapOf(down.id to down.position)
        val velocity = VelocityTracker().apply { addPosition(down.uptimeMillis, down.position) }
        fun inCancelCorner(position: Offset) = position.y in 0f..(height * .15f) &&
            (position.x in 0f..(width * .15f) || position.x in (width * .85f)..width)

        try {
            while (true) {
                val event = awaitPointerEvent()
                if (event.changes.any { it.isConsumed }) break
                val primary = event.changes.firstOrNull { it.id == down.id }
                val touches = event.changes.filter { it.pressed }
                if (touches.size > 1 || pressedTogether) {
                    hold?.cancel()
                    if (locked || !fullscreen || moved || held || touches.size > 2) break
                    pressedTogether = true
                    if (touches.size == 2) {
                        val span = (touches[0].position - touches[1].position).getDistance()
                        if (pinchSpan == 0f) {
                            pinchSpan = span
                            lastPinchSpan = span
                        }
                        if (!pinching && abs(span - pinchSpan) > slop) pinching = true
                        if (pinching && lastPinchSpan > 0f) onPinch(span / lastPinchSpan)
                        lastPinchSpan = span
                    }
                    if (event.changes.any { (it.position - startingPositions.getOrPut(it.id) { it.position }).getDistance() > slop }) multiTouchMoved = true
                    event.changes.forEach { it.consume() }
                    if (touches.isEmpty()) {
                        if (!pinching && !multiTouchMoved && event.changes.first().uptimeMillis - down.uptimeMillis <= 300) onTwoFingerTap()
                        break
                    }
                    continue
                }
                if (primary == null) break
                val delta = primary.position - down.position
                if (direction == null && !held && delta.getDistance() > slop) {
                    moved = true
                    hold?.cancel()
                    if (locked) break
                    direction = when {
                        abs(delta.x) > abs(delta.y) * 1.15f -> PlayerDrag.SEEK
                        abs(delta.y) > abs(delta.x) * 1.15f -> when {
                            fullscreen && portrait && down.position.x / width in 0.4f..0.6f -> PlayerDrag.DISMISS
                            down.position.x < width * .5f -> PlayerDrag.BRIGHTNESS
                            else -> PlayerDrag.VOLUME
                        }
                        else -> null
                    }
                    direction?.let { onDrag(it, PlayerDragPhase.START, 0f) }
                }
                val drag = direction
                if (drag != null) {
                    primary.consume()
                    val cancelZone = drag == PlayerDrag.SEEK && !inCancelCorner(down.position) && inCancelCorner(primary.position)
                    val fraction = if (drag == PlayerDrag.SEEK) delta.x / width else -delta.y / height
                    velocity.addPosition(primary.uptimeMillis, primary.position)
                    if (primary.changedToUpIgnoreConsumed()) {
                        if (drag == PlayerDrag.DISMISS && delta.y > abs(delta.x) * 1.35f &&
                            (delta.y >= 80.dp.toPx() || delta.y >= 28.dp.toPx() && velocity.calculateVelocity().y >= 700.dp.toPx())) onDismiss()
                        onDrag(drag, if (cancelZone) PlayerDragPhase.CANCEL else PlayerDragPhase.COMMIT, fraction)
                        committed = true
                        break
                    }
                    onDrag(drag, if (cancelZone) PlayerDragPhase.CANCEL_ZONE else PlayerDragPhase.UPDATE, fraction)
                } else if (primary.changedToUpIgnoreConsumed()) {
                    primary.consume()
                    if (!held && !moved) {
                        if (doubleTap) onDoubleTap()
                        else if (locked) onTap()
                        else {
                            singleTap?.cancel()
                            tapUpTime = primary.uptimeMillis
                            tapUpPosition = primary.position
                            singleTap = launch { delay(viewConfiguration.doubleTapTimeoutMillis); onTap() }
                        }
                    }
                    break
                } else if (held) {
                    primary.consume()
                }
            }
        } finally {
            hold?.cancel()
            if (held) onHold(false)
            if (!committed) direction?.let { onDrag(it, PlayerDragPhase.CANCEL, 0f) }
        }
    }
}

package app.bilight.android.playback

/** Tracks visibility without replacing the live player's play/pause intent. */
class PlaybackVisibility {
    var background = false; private set
    fun leave(wantsPlay: Boolean) { background=true }
    fun enter(): Boolean { background=false; return false }
    fun prepared(autoplay: Boolean): Boolean = autoplay
    fun currentIntent(wantsPlay: Boolean): Boolean = wantsPlay
}

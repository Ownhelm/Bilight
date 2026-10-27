package app.bilight.android.playback

/** Records playback intent across lifecycle callbacks, including a source prepared while hidden. */
class PlaybackVisibility {
    var background = false; private set
    private var resume = false
    fun leave(wantsPlay: Boolean) { if (background) return; background=true; resume=wantsPlay }
    fun enter(): Boolean { if (!background) return false; background=false; return resume.also { resume=false } }
    fun prepared(autoplay: Boolean): Boolean {
        if (!background) return autoplay
        resume=autoplay; return false
    }
    fun currentIntent(wantsPlay: Boolean): Boolean = if (background) resume else wantsPlay
}

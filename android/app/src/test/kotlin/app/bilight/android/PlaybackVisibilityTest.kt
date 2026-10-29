package app.bilight.android

import app.bilight.android.playback.PlaybackVisibility
import org.junit.Assert.*
import org.junit.Test

class PlaybackVisibilityTest {
    @Test fun duplicateStopDoesNotRestartPlaybackOnReturn() {
        val state=PlaybackVisibility(); state.leave(true); state.leave(false)
        assertFalse(state.enter()); assertFalse(state.enter())
    }
    @Test fun aSourcePreparedInTheBackgroundKeepsItsAutoplayIntent() {
        val state=PlaybackVisibility(); state.leave(false)
        assertTrue(state.prepared(true)); assertFalse(state.enter())
    }
    @Test fun aUserPausedVideoStaysPausedAcrossHomeAndResume() {
        val state=PlaybackVisibility(); state.leave(false); assertFalse(state.enter())
    }
}

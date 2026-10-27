package app.bilight.android

import app.bilight.android.playback.PlaybackVisibility
import org.junit.Assert.*
import org.junit.Test

class PlaybackVisibilityTest {
    @Test fun duplicateStopCannotReplaceTheOriginalPlayIntentWithTheLifecyclePause() {
        val state=PlaybackVisibility(); state.leave(true); state.leave(false)
        assertTrue(state.enter()); assertFalse(state.enter())
    }
    @Test fun aSourcePreparedInTheBackgroundWaitsAndResumesWhenVisible() {
        val state=PlaybackVisibility(); state.leave(false)
        assertFalse(state.prepared(true)); assertTrue(state.enter())
    }
    @Test fun aUserPausedVideoStaysPausedAcrossHomeAndResume() {
        val state=PlaybackVisibility(); state.leave(false); assertFalse(state.enter())
    }
}

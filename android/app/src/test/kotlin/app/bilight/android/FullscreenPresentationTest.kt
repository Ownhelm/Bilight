package app.bilight.android

import app.bilight.android.playback.fullscreenPresentation
import org.junit.Assert.*
import org.junit.Test

class FullscreenPresentationTest {
    @Test fun enterWaitsForTheLandscapeWindowInsteadOfStretchingThePortraitPage() {
        assertFalse(fullscreenPresentation(true,false,false,false,false))
        assertTrue(fullscreenPresentation(true,false,true,false,false))
    }
    @Test fun exitKeepsTheLandscapePlayerFullUntilPortraitWindowArrives() {
        assertTrue(fullscreenPresentation(false,false,true,false,true))
        assertFalse(fullscreenPresentation(false,false,false,false,true))
    }
    @Test fun portraitVideosAndForegroundReturnDoNotLoseFullscreen() {
        assertTrue(fullscreenPresentation(true,true,false,false,false))
        assertTrue(fullscreenPresentation(true,false,false,true,false))
        assertFalse(fullscreenPresentation(false,false,false,true,false))
    }
}

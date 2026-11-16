@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package app.bilight.android

import app.bilight.android.playback.PlaybackPosture
import app.bilight.android.playback.PlaybackRotation
import app.bilight.android.playback.fullscreenPresentation
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
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

    @Test fun onlyNearHorizontalAnglesCountAndDriftOnTheSameSideDoesNotRestartConfirmation() = runTest {
        val rotation = PlaybackRotation(this)
        val postures = mutableListOf<PlaybackPosture>()
        for (angle in listOf(60, 74, 106, 240, 254, 286)) {
            rotation.update(angle, postures::add)
            advanceTimeBy(300)
        }
        assertTrue(postures.isEmpty())

        rotation.update(75, postures::add)
        advanceTimeBy(100)
        rotation.update(90, postures::add)
        advanceTimeBy(149)
        assertTrue(postures.isEmpty())
        advanceTimeBy(1)
        runCurrent()
        rotation.update(105, postures::add)
        advanceTimeBy(300)
        assertEquals(listOf(PlaybackPosture.LANDSCAPE_LEFT), postures)
    }

    @Test fun flatSamplesAndSwitchingSidesCancelAnUnconfirmedLandscape() = runTest {
        val rotation = PlaybackRotation(this)
        val postures = mutableListOf<PlaybackPosture>()
        rotation.update(90, postures::add)
        advanceTimeBy(200)
        rotation.update(-1, postures::add)
        advanceTimeBy(250)
        assertTrue(postures.isEmpty())

        rotation.update(90, postures::add)
        advanceTimeBy(200)
        rotation.update(270, postures::add)
        advanceTimeBy(249)
        assertTrue(postures.isEmpty())
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(PlaybackPosture.LANDSCAPE_RIGHT), postures)
    }

    @Test fun uprightWrapsThroughZeroAndBackgroundResetCancelsPendingRotation() = runTest {
        val rotation = PlaybackRotation(this)
        val postures = mutableListOf<PlaybackPosture>()
        rotation.update(20, postures::add)
        advanceTimeBy(125)
        rotation.update(350, postures::add)
        advanceTimeBy(125)
        runCurrent()
        assertEquals(PlaybackPosture.UPRIGHT, rotation.settled)

        rotation.update(270, postures::add)
        advanceTimeBy(249)
        rotation.reset()
        advanceTimeBy(300)
        assertNull(rotation.settled)
        assertEquals(listOf(PlaybackPosture.UPRIGHT), postures)
    }
}

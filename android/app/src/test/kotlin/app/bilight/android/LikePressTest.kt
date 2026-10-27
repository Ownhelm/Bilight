@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package app.bilight.android

import app.bilight.android.playback.LikePress
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

class LikePressTest {
    @Test fun shortTapLikesAndCompletedHoldTriplesExactlyOnce() = runTest {
        var likes=0; var triples=0; var charging=false
        val press=LikePress(this,{ true },{ likes++ },{ triples++ },{ charging=it })
        press.begin(); advanceTimeBy(499); press.end(); assertEquals(1,likes); assertEquals(0,triples)
        press.begin(); advanceTimeBy(500); runCurrent(); assertTrue(charging)
        advanceTimeBy(1500); runCurrent(); press.end(); assertEquals(1,likes); assertEquals(1,triples)
    }
    @Test fun releaseOrMovingAwayAfterChargeStartsCannotBecomeALike() = runTest {
        var writes=0
        val press=LikePress(this,{ true },{ writes++ },{ writes++ },{})
        press.begin(); advanceTimeBy(800); press.end(); advanceUntilIdle(); assertEquals(0,writes)
        press.begin(); advanceTimeBy(800); press.cancel(); advanceUntilIdle(); assertEquals(0,writes)
    }
    @Test fun anAlreadyCompletedTripleDoesNotWriteAgainOrFallBackToLike() = runTest {
        var writes=0
        val press=LikePress(this,{ false },{ writes++ },{ writes++ },{})
        press.begin(); advanceTimeBy(2200); press.end(); assertEquals(0,writes)
    }
}

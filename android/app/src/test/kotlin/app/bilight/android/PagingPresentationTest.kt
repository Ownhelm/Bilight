package app.bilight.android

import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.snapshots.SnapshotStateObserver
import app.bilight.android.core.Page
import app.bilight.android.ui.Paging
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class PagingPresentationTest {
    @Test fun anEmptyFirstPageInvalidatesTheUiThatWasWaitingForItsLoadedState() = runTest {
        val paging=Paging<String>(); var invalidated=false
        val observer=SnapshotStateObserver { it() }
        observer.start()
        try {
            observer.observeReads(Unit,{ invalidated=true }) { assertEquals(0,paging.page) }
            paging.load { _,_ -> Page(emptyList(),false) }
            Snapshot.sendApplyNotifications()
            assertTrue("An empty successful response left the page visually blank",invalidated)
        } finally { observer.stop(); observer.clear() }
    }
}

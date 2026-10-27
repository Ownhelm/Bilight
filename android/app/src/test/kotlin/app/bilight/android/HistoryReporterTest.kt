@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

class HistoryReporterTest {
    private val part = Part(1,1,"P1",120)
    private val detail = Detail(Video("BV1NGZtBwELa",42,"测试",null,120,0,User(1,"演示",null),0),listOf(part),"",2,Statistics(0,0,0))
    @Test fun failedCloudReportIsRetainedUntilARealRetry() = runTest {
        var unavailable = true; val sent = mutableListOf<Long>(); var message: String? = null
        val queue = HistoryReporter(this,{ if (unavailable) error("离线"); sent += it.progress },{ message=it })
        queue.account(1); queue.submit(HistoryReport(detail,part,10,1)); runCurrent()
        assertTrue(sent.isEmpty()); assertTrue(message!!.contains("离线"))
        unavailable = false; queue.retry(); runCurrent()
        assertEquals(listOf(10L),sent); assertNull(message)
    }
    @Test fun newerProgressCannotBeOverwrittenByAnEarlierInFlightWrite() = runTest {
        val gate = CompletableDeferred<Unit>(); val sent = mutableListOf<Long>()
        val queue = HistoryReporter(this,{ if (it.progress==10L) gate.await(); sent += it.progress },{})
        queue.account(1); queue.submit(HistoryReport(detail,part,10,1)); runCurrent()
        queue.submit(HistoryReport(detail,part,3,1)); gate.complete(Unit); runCurrent()
        assertEquals(listOf(10L,3L),sent)
    }
    @Test fun accountChangeCancelsPendingAndRejectsOldResponses() = runTest {
        val gate = CompletableDeferred<Unit>(); val sent = mutableListOf<Long>()
        val queue = HistoryReporter(this,{ gate.await(); sent += it.progress },{})
        queue.account(1); queue.submit(HistoryReport(detail,part,10,1)); runCurrent()
        queue.account(2); queue.submit(HistoryReport(detail,part,20,1)); gate.complete(Unit); runCurrent()
        assertTrue(sent.isEmpty())
    }
}

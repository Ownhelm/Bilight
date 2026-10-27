package app.bilight.android.core

import kotlinx.coroutines.*

data class HistoryReport(val detail: Detail, val part: Part, val progress: Long, val version: Long)

/** Session-only retry queue. A newer pause/seek position always follows an in-flight older report. */
class HistoryReporter(
    private val scope: CoroutineScope,
    private val send: suspend (HistoryReport) -> Unit,
    private val failure: (String?) -> Unit
) {
    private val pending = linkedMapOf<Long, HistoryReport>()
    private var version = -1L
    private var worker: Job? = null
    fun account(value: Long) {
        if (version == value) return
        version = value; worker?.cancel(); worker = null; pending.clear(); failure(null)
    }
    fun submit(value: HistoryReport) {
        if (value.version != version) return
        pending[value.part.cid] = value
        retry()
    }
    fun retry() {
        if (worker?.isActive == true || pending.isEmpty()) return
        val ticket = version
        worker = scope.launch {
            while (isActive && ticket == version && pending.isNotEmpty()) {
                val report = pending.values.first()
                try {
                    send(report)
                    if (ticket != version) return@launch
                    if (pending[report.part.cid] === report) pending.remove(report.part.cid)
                    failure(null)
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { if (ticket == version) failure("历史同步失败：${e.message ?: "请重试。"}"); return@launch }
            }
        }
    }
}

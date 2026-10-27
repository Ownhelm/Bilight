package app.bilight.android

import android.app.Application
import app.bilight.android.core.*
import app.bilight.android.downloads.DownloadStore

/** One account and transfer owner per process, shared by the UI and foreground download service. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class BilightApplication: Application() {
    override fun onCreate() {
        super.onCreate()
        // Playback errors are presented by the app; third-party diagnostics must not log signed media URLs.
        androidx.media3.common.util.Log.setLogLevel(androidx.media3.common.util.Log.LOG_LEVEL_OFF)
    }
    val http by lazy { BiliHttp(SessionVault(this)) }
    val repository by lazy { BiliRepository(http) }
    val downloads by lazy { DownloadStore(this, repository) }
}

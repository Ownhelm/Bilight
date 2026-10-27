package app.bilight.android.downloads

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import app.bilight.android.BilightApplication
import app.bilight.android.MainActivity
import app.bilight.android.R

class DownloadService: Service() {
    private val store get() = (application as BilightApplication).downloads
    private fun notification(item: DownloadRecord?): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, "downloads").setSmallIcon(R.drawable.ic_download_notification)
            .setContentTitle("Bilight 下载").setContentText(item?.let { "${it.state.label} · ${it.video.title}" } ?: "正在准备下载")
            .setOnlyAlertOnce(true).setOngoing(true).setContentIntent(open)
            .setProgress(100, item?.takeIf { it.total > 0 }?.let { (it.received * 100 / it.total).toInt() } ?: 0, item?.total == 0L).build()
    }
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("downloads", "视频下载", NotificationManager.IMPORTANCE_LOW))
        if (Build.VERSION.SDK_INT >= 29) startForeground(3881, notification(null), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else startForeground(3881, notification(null))
        store.onProgress = { item -> if (item != null) getSystemService(NotificationManager::class.java).notify(3881, notification(item)) }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        store.processQueue { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        return START_NOT_STICKY
    }
    override fun onDestroy() { store.onProgress = null; store.pauseAll(); super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onTimeout(startId: Int, fgsType: Int) { store.pauseAll(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
}

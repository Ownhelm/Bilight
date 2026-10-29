package app.bilight.android.playback

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import app.bilight.android.MainActivity

/** Hosts the active screen's existing player; backgrounding never creates a second decoder. */
class PlaybackService: MediaSessionService() {
    private var session: MediaSession? = null
    companion object {
        private var current: PlaybackModel? = null
        private var service: PlaybackService? = null
        fun attach(context: Context, model: PlaybackModel) {
            if (current===model && service?.session?.player===model.player) return
            current=model
            context.startService(Intent(context,PlaybackService::class.java))
        }
        fun detach(context: Context, model: PlaybackModel) {
            if (current!==model) return
            current=null
            service?.disconnect()
            context.stopService(Intent(context,PlaybackService::class.java))
        }
    }
    override fun onCreate() { super.onCreate(); service=this; current?.let(::connect) ?: stopSelf() }
    private fun connect(model: PlaybackModel) {
        if (session?.player===model.player) return
        disconnect()
        val open=PendingIntent.getActivity(this,3882,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        session=MediaSession.Builder(this,model.player).setSessionActivity(open).build().also(::addSession)
    }
    private fun disconnect() { session?.let { removeSession(it); it.release() }; session=null }
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        current?.let(::connect) ?: stopSelf()
        return super.onStartCommand(intent,flags,startId)
    }
    override fun onTaskRemoved(rootIntent: Intent?) { current?.close(); stopSelf() }
    override fun onDestroy() { service=null; disconnect(); super.onDestroy() }
}

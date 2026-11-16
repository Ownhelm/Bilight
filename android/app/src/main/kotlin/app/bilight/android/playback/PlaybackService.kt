package app.bilight.android.playback

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import app.bilight.android.MainActivity
import app.bilight.android.R
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/** Hosts the active screen's existing player; backgrounding never creates a second decoder. */
@OptIn(UnstableApi::class)
class PlaybackService: MediaSessionService() {
    private var session: MediaSession? = null
    companion object {
        private val seekBack = SessionCommand("app.bilight.android.SEEK_BACK_10", Bundle.EMPTY)
        private val seekForward = SessionCommand("app.bilight.android.SEEK_FORWARD_10", Bundle.EMPTY)
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
        session=MediaSession.Builder(this,model.player)
            .setSessionActivity(open)
            .setMediaButtonPreferences(listOf(
                CommandButton.Builder(CommandButton.ICON_SKIP_BACK_10)
                    .setDisplayName(getString(R.string.media_seek_back_10))
                    .setSessionCommand(seekBack).setSlots(CommandButton.SLOT_BACK).build(),
                CommandButton.Builder(CommandButton.ICON_SKIP_FORWARD_10)
                    .setDisplayName(getString(R.string.media_seek_forward_10))
                    .setSessionCommand(seekForward).setSlots(CommandButton.SLOT_FORWARD).build(),
            ))
            .setCallback(mediaControls)
            .build().also(::addSession)
    }
    // SystemUI reads custom session actions and prioritizes standard previous/next actions.
    private val mediaControls = object : MediaSession.Callback {
        override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult =
            MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                    .add(seekBack).add(seekForward).build())
                .setAvailablePlayerCommands(MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS.buildUpon()
                    .remove(Player.COMMAND_SEEK_TO_PREVIOUS).remove(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                    .remove(Player.COMMAND_SEEK_TO_NEXT).remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                    .build())
                .build()

        override fun onCustomCommand(
            session: MediaSession, controller: MediaSession.ControllerInfo, command: SessionCommand, args: Bundle,
        ): ListenableFuture<SessionResult> {
            val playerCommand = when (command.customAction) {
                seekBack.customAction -> Player.COMMAND_SEEK_BACK
                seekForward.customAction -> Player.COMMAND_SEEK_FORWARD
                else -> return super.onCustomCommand(session, controller, command, args)
            }
            val player = session.player
            if (!player.isCommandAvailable(playerCommand)) {
                return Futures.immediateFuture(SessionResult(SessionResult.RESULT_ERROR_INVALID_STATE))
            }
            if (playerCommand == Player.COMMAND_SEEK_BACK) player.seekBack() else player.seekForward()
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
        }
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

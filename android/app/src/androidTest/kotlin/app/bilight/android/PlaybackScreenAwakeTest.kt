@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
package app.bilight.android

import android.view.View
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.FlagSet
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.playback.PlaybackScreenAwake
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy

class PlaybackScreenAwakeTest {
    private class Owner : LifecycleOwner {
        override val lifecycle = LifecycleRegistry(this)
    }
    private class Playback {
        var ready = true
        var state = Player.STATE_READY
        var suppression = Player.PLAYBACK_SUPPRESSION_REASON_NONE
        var error: PlaybackException? = null
        val listeners = mutableListOf<Player.Listener>()
        val player = Proxy.newProxyInstance(Player::class.java.classLoader, arrayOf(Player::class.java)) { proxy, method, args ->
            when (method.name) {
                "getPlayWhenReady" -> ready
                "getPlaybackState" -> state
                "getPlaybackSuppressionReason" -> suppression
                "getPlayerError" -> error
                "addListener" -> { listeners.add(args!![0] as Player.Listener); null }
                "removeListener" -> { listeners.remove(args!![0] as Player.Listener); null }
                "equals" -> proxy === args?.get(0)
                "hashCode" -> System.identityHashCode(proxy)
                "toString" -> "Isolated playback state"
                else -> error("Unexpected Player method: ${method.name}")
            }
        } as Player
        val events = Player.Events(FlagSet.Builder().add(Player.EVENT_PLAYBACK_STATE_CHANGED).build())
        fun changed() { listeners.toList().forEach { it.onEvents(player, events) } }
    }

    @Test fun onlyForegroundPlaybackAndBufferingKeepTheRealViewAwake() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val owner = Owner(); owner.lifecycle.currentState = Lifecycle.State.RESUMED
            val view = View(ApplicationProvider.getApplicationContext())
            val playback = Playback()
            val binding = PlaybackScreenAwake(view, playback.player, owner.lifecycle)
            try {
                assertTrue(view.keepScreenOn)
                playback.state = Player.STATE_BUFFERING; playback.changed()
                assertTrue("Buffering during playback must not release the display", view.keepScreenOn)
                playback.ready = false; playback.changed()
                assertFalse("Paused buffering must allow normal screen sleep", view.keepScreenOn)
                playback.ready = true; playback.state = Player.STATE_ENDED; playback.changed()
                assertFalse("Ended players may retain playWhenReady=true", view.keepScreenOn)
                playback.state = Player.STATE_IDLE; playback.changed(); assertFalse(view.keepScreenOn)
                playback.state = Player.STATE_READY; playback.changed(); assertTrue(view.keepScreenOn)
                playback.suppression = Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS
                playback.changed(); assertFalse(view.keepScreenOn)
                playback.suppression = Player.PLAYBACK_SUPPRESSION_REASON_NONE
                playback.error = PlaybackException("Isolated failure", null, PlaybackException.ERROR_CODE_UNSPECIFIED)
                playback.changed(); assertFalse(view.keepScreenOn)
                playback.error = null; playback.changed(); assertTrue(view.keepScreenOn)
                owner.lifecycle.currentState = Lifecycle.State.STARTED
                assertFalse("Leaving the foreground must release the display even if audio keeps playing", view.keepScreenOn)
                playback.changed(); assertFalse(view.keepScreenOn)
                owner.lifecycle.currentState = Lifecycle.State.RESUMED; assertTrue(view.keepScreenOn)
                val oldListener = playback.listeners.single()
                owner.lifecycle.currentState = Lifecycle.State.DESTROYED
                assertFalse(view.keepScreenOn); assertTrue(playback.listeners.isEmpty())
                oldListener.onEvents(playback.player, playback.events)
                assertFalse("A late player event cannot re-enable an exited page", view.keepScreenOn)
            } finally { binding.close() }
        }
    }

    @Test fun closingRestoresAnExistingAwakeRequest() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val owner = Owner(); owner.lifecycle.currentState = Lifecycle.State.RESUMED
            val view = View(ApplicationProvider.getApplicationContext()).apply { keepScreenOn = true }
            val playback = Playback().apply { ready = false }
            val binding = PlaybackScreenAwake(view, playback.player, owner.lifecycle)
            assertTrue(view.keepScreenOn)
            binding.close(); binding.close()
            assertTrue("This binding must preserve the view's earlier awake request", view.keepScreenOn)
            assertTrue(playback.listeners.isEmpty()); assertEquals(0, owner.lifecycle.observerCount)
        }
    }
}

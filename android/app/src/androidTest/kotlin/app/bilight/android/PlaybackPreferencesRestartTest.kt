package app.bilight.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.playback.PlaybackSettings
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Run twice, with an explicit process stop between seed and verify, in the separate anonymous app. */
class PlaybackPreferencesRestartTest {
    @Test fun explicitPreferencesSurviveProcessRestart() {
        val phase=InstrumentationRegistry.getArguments().getString("bilightPreferenceRestartPhase")
        assumeTrue(phase=="seed" || phase=="verify")
        val context=ApplicationProvider.getApplicationContext<Context>()
        check(context.packageName=="app.bilight.android.awakeverification")
        val preferences=PlaybackSettings(context)
        if (phase=="seed") {
            preferences.subtitlesEnabled=false; preferences.subtitleLanguage="en"; preferences.speed=1.5f
            preferences.danmaku=true; preferences.font=24; preferences.area=.5f; preferences.opacity=.75f; preferences.quality=120
            check(context.getSharedPreferences("playback-preferences",Context.MODE_PRIVATE).edit().putBoolean("restartProbe",true).commit())
        } else {
            assertTrue(context.getSharedPreferences("playback-preferences",Context.MODE_PRIVATE).getBoolean("restartProbe",false))
            assertFalse(preferences.subtitlesEnabled); assertEquals("en",preferences.subtitleLanguage)
            assertEquals(1.5f,preferences.speed); assertTrue(preferences.danmaku); assertEquals(24,preferences.font)
            assertEquals(.5f,preferences.area); assertEquals(.75f,preferences.opacity); assertEquals(120,preferences.quality)
        }
        println("Preference restart probe $phase PID=${android.os.Process.myPid()}")
    }
}

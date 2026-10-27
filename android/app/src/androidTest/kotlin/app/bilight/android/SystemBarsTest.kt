package app.bilight.android

import androidx.core.view.WindowCompat
import androidx.test.ext.junit.rules.ActivityScenarioRule
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Run with the system in dark mode too: Bilight's pages remain white. */
class SystemBarsTest {
    @get:Rule val activity=ActivityScenarioRule(MainActivity::class.java)
    @Test fun whitePagesKeepReadableSystemBarIcons() {
        activity.scenario.onActivity {
            val controller=WindowCompat.getInsetsController(it.window,it.window.decorView)
            assertTrue("White pages require dark status-bar text",controller.isAppearanceLightStatusBars)
            assertTrue("White pages require dark navigation icons",controller.isAppearanceLightNavigationBars)
        }
    }
}

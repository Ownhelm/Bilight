package app.bilight.android

import android.content.Intent
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import app.bilight.android.core.AppModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class LauncherResumeTest {
    @get:Rule val activity=ActivityScenarioRule<MainActivity>(Intent(ApplicationProvider.getApplicationContext(),MainActivity::class.java))
    @Test fun desktopIconReturnsToTheExistingActivityAndViewModel() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        lateinit var screen: MainActivity
        lateinit var model: AppModel
        activity.scenario.onActivity { screen=it; model=ViewModelProvider(it)[AppModel::class.java]; model.keyword="launcher-resume-regression" }
        instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_HOME").close()
        Thread.sleep(300)
        val launch=screen.packageManager.getLaunchIntentForPackage(screen.packageName)!!
        screen.applicationContext.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED))
        var resumed: MainActivity?=null
        val deadline=android.os.SystemClock.elapsedRealtime()+10000
        while (resumed==null && android.os.SystemClock.elapsedRealtime()<deadline) {
            instrumentation.runOnMainSync { resumed=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull() }
            if (resumed==null) Thread.sleep(50)
        }
        assertNotNull("Bilight did not return to foreground",resumed)
        assertSame("Desktop launch created another MainActivity and discarded the playback page",screen,resumed)
        lateinit var restored: AppModel
        instrumentation.runOnMainSync {
            restored=ViewModelProvider(resumed!!)[AppModel::class.java]
        }
        assertSame(model,restored); assertEquals("launcher-resume-regression",restored.keyword)
    }
}

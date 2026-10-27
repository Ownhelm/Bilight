package app.bilight.android

import android.view.WindowManager
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import app.bilight.android.core.AppModel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Opt-in production UI, using only this App's own login; exports counts, never account content. */
class LiveFollowingScrollTest {
    @get:Rule val rule=createEmptyComposeRule()
    @Test fun realUserSwipesAppendBeyondTheFirstServerPage() {
        val args=InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("liveFollowingScroll")=="true" && args.getString("allowAccountRead")=="true")
        // Launch Bilight explicitly from adb after the runner starts; Xiaomi blocks Scenario's launch.
        lateinit var activity: MainActivity
        rule.waitUntil(30000) {
            var resumed: MainActivity?=null
            rule.runOnUiThread { resumed=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull() }
            resumed?.let { activity=it };resumed!=null
        }
        lateinit var model: AppModel
        var originalKeepScreenOn=false
        rule.runOnUiThread {
            model=ViewModelProvider(activity)[AppModel::class.java]
            originalKeepScreenOn=activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON!=0
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        try {
            rule.waitUntil(30000) { !model.restoring }
            check(model.user!=null) { "请先在 Bilight 内登录。" }
            rule.runOnIdle { model.routes.clear();model.tab=1 }
            rule.waitUntil(30000) { model.feedLoaded && !model.feedBusy || model.feedError!=null }
            assertNull(model.feedError)
            val initial=model.following.size
            assertTrue("The real account did not return any followed posts",initial>0)
            var attempts=0
            while(model.following.size<=initial && attempts++<40) {
                assertNull(model.feedError)
                if(!model.feedMore && !model.feedBusy) break
                rule.runOnUiThread { check(activity.hasWindowFocus()) { "请保持 Bilight 在前台并解锁屏幕。" } }
                rule.onNode(hasScrollAction()).performTouchInput { swipeUp(durationMillis=180) }
                Thread.sleep(120)
            }
            rule.waitUntil(25000) { !model.feedBusy }
            assertNull(model.feedError)
            assertTrue("Real user swipes never appended the next page",model.following.size>initial)
            InstrumentationRegistry.getInstrumentation().sendStatus(0,android.os.Bundle().apply {
                putString("stream","BILIGHT_FOLLOWING_SCROLL "+JSONObject().put("initial_count",initial).put("final_count",model.following.size).put("swipes",attempts).put("has_more",model.feedMore).toString()+"\n")
            })
        } finally {
            if(!originalKeepScreenOn) rule.runOnUiThread { activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
        }
    }
}

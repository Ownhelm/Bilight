package app.bilight.android

import android.view.View
import android.webkit.WebView
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.AppModel
import app.bilight.android.core.SessionVault
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Explicit anonymous emulator audit only; never fills a form or requests a verification code. */
class OfficialLoginLayoutTest {
    @get:Rule val rule=createAndroidComposeRule<MainActivity>()
    @Test fun officialFormKeepsTermsAndSubmitButtonSeparate() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        assumeTrue(InstrumentationRegistry.getArguments().getString("loginLayoutAudit")=="true")
        check(android.os.Build.HARDWARE in listOf("ranchu","goldfish"))
        check(SessionVault(rule.activity).load()==null)
        val app=ViewModelProvider(rule.activity)[AppModel::class.java]
        rule.waitUntil(5000) { !app.restoring }
        rule.runOnIdle { app.showLogin=true }; rule.onNodeWithText("手机验证").performClick()
        rule.waitForIdle(); Thread.sleep(5000)
        // Dialogs live in another window; select this app's rendered WebView through the UI roots.
        lateinit var web: WebView
        run {
            val roots=androidx.test.espresso.matcher.RootMatchers.isDialog()
            androidx.test.espresso.Espresso.onView(androidx.test.espresso.matcher.ViewMatchers.isAssignableFrom(WebView::class.java)).inRoot(roots)
                .perform(object: androidx.test.espresso.ViewAction {
                    override fun getDescription()="Inspect the anonymous official login layout"
                    override fun getConstraints()=androidx.test.espresso.matcher.ViewMatchers.isAssignableFrom(WebView::class.java)
                    override fun perform(controller: androidx.test.espresso.UiController,view: View) { web=view as WebView }
                })
        }
        val folder=File(rule.activity.filesDir,"login-layout-audit").apply { mkdirs() }
        val done=CountDownLatch(1); var output=""
        rule.runOnUiThread {
            web.evaluateJavascript("""JSON.stringify({button:Array.from(document.querySelectorAll('.login-btn')).find(e=>e.getBoundingClientRect().height>0)?.getBoundingClientRect().toJSON(),terms:document.querySelector('.explain-tips')?.getBoundingClientRect().toJSON()})""") { output=it; done.countDown() }
        }
        assertTrue(done.await(5,TimeUnit.SECONDS)); File(folder,"layout.json").writeText(output)
        val bitmap=instrumentation.uiAutomation.takeScreenshot()
        File(folder,"official-phone.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }; bitmap.recycle()
        val layout=org.json.JSONObject(org.json.JSONTokener(output).nextValue() as String)
        val button=layout.getJSONObject("button"); val terms=layout.getJSONObject("terms")
        assertTrue("Official terms overlapped the login button",terms.getDouble("top")>=button.getDouble("bottom")+12)
        assertTrue("Official terms overflowed horizontally",terms.getDouble("left")>=0 && terms.getDouble("right")<=web.width/web.resources.displayMetrics.density+1)
        rule.runOnIdle { app.showLogin=false }
    }
}

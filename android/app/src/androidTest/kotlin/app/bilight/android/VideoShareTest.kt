package app.bilight.android

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.graphics.asAndroidBitmap
import java.io.File
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.ui.VideoShareSheet
import app.bilight.android.ui.videoShareIntent
import app.bilight.android.ui.videoShareUrl
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Public video links only; no account, platform SDK or real external post. */
class VideoShareTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()
    @Test fun systemShareContainsTheSelectedPartLink() {
        val url=videoShareUrl("BV1xx411c7mD",3)
        assertEquals("https://www.bilibili.com/video/BV1xx411c7mD/?p=3",url)
        assertEquals("https://www.bilibili.com/video/BV1xx411c7mD/",videoShareUrl("BV1xx411c7mD",1))
        val intent=videoShareIntent("分享测试",url)
        assertEquals(Intent.ACTION_SEND,intent.action); assertEquals("text/plain",intent.type)
        assertEquals("分享测试\n$url",intent.getStringExtra(Intent.EXTRA_TEXT))
    }
    @Test fun copyClosesTheTwoActionSheetWithoutLogin() {
        var closed = false
        rule.runOnUiThread { rule.activity.findViewById<android.view.ViewGroup>(android.R.id.content).removeAllViews() }
        rule.setContent { MaterialTheme { VideoShareSheet("BV1xx411c7mD","分享测试",2) { closed = true } } }
        rule.onNodeWithText("系统分享").assertIsDisplayed()
        rule.onNodeWithText("二维码").assertDoesNotExist()
        rule.onNodeWithText("更多").assertDoesNotExist()
        val panel = rule.onNodeWithTag("video-share-sheet")
        val bitmap = panel.captureToImage().asAndroidBitmap()
        File(rule.activity.cacheDir, "share-compact-panel.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        rule.onNodeWithText("复制链接").performClick()
        rule.runOnIdle {
            assertTrue(closed)
            val automation=InstrumentationRegistry.getInstrumentation().uiAutomation
            automation.adoptShellPermissionIdentity("android.permission.READ_CLIPBOARD_IN_BACKGROUND")
            try {
                val clipboard=rule.activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                assertEquals(videoShareUrl("BV1xx411c7mD",2),clipboard.primaryClip?.getItemAt(0)?.text?.toString())
            } finally { automation.dropShellPermissionIdentity() }
        }
    }
}

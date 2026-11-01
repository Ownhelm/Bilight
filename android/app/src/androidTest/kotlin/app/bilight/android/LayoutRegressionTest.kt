package app.bilight.android

import android.view.ViewGroup
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import app.bilight.android.ui.ActionBarLayout
import app.bilight.android.ui.OfflineCommentsNotice
import androidx.compose.ui.graphics.asAndroidBitmap
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class LayoutRegressionTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()
    @Test fun offlineCommentNoticeWrapsAndKeepsItsRetryReachableWithLargeText() {
        rule.runOnUiThread { rule.activity.findViewById<ViewGroup>(android.R.id.content).removeAllViews() }
        var scale by mutableFloatStateOf(1f)
        rule.setContent {
            val density=LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density,scale)) {
                androidx.compose.material3.MaterialTheme {
                    Box(Modifier.width(320.dp).testTag("offline-notice")) { OfflineCommentsNotice(true) {} }
                }
            }
        }
        rule.onNodeWithText("当前处于离线状态").assertIsDisplayed()
        rule.onNodeWithText("缓存视频可继续播放，联网后即可查看评论。").assertIsDisplayed()
        val normal=rule.onNodeWithTag("offline-notice").getUnclippedBoundsInRoot()
        fun save(name: String) {
            val image=rule.onNodeWithTag("offline-notice").captureToImage().asAndroidBitmap()
            java.io.File(rule.activity.getExternalFilesDir(null),name).outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }
        }
        save("offline-comments.png")
        rule.runOnIdle { scale=2f }; rule.waitForIdle()
        val large=rule.onNodeWithTag("offline-notice").getUnclippedBoundsInRoot()
        val retry=rule.onNodeWithText("重新加载").assertIsDisplayed().getUnclippedBoundsInRoot()
        assertTrue(large.bottom-large.top>normal.bottom-normal.top); assertTrue(retry.bottom-retry.top>=44.dp)
        assertTrue(retry.left>=large.left && retry.right<=large.right)
        save("offline-comments-large.png")
    }
    @Test fun actionSpacingAndLargeFontFallbackUseTheActualSharedLayout() {
        rule.runOnUiThread { rule.activity.findViewById<ViewGroup>(android.R.id.content).removeAllViews() }
        var width by mutableIntStateOf(288); var scale by mutableFloatStateOf(1f)
        rule.setContent {
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density,scale)) {
                Box(Modifier.width(width.dp)) {
                    ActionBarLayout(like={ Text("赞",it.heightIn(min=58.dp).testTag("like")) },coin={ Text("币",it.heightIn(min=58.dp).testTag("coin")) },favorite={ Text("藏",it.heightIn(min=58.dp).testTag("favorite")) },share={ Text("转发",it.heightIn(min=58.dp).testTag("share")) },download={ Text("下载",it.heightIn(min=58.dp).testTag("download")) })
                }
            }
        }
        for (size in listOf(288,343,358,398,408)) {
            rule.runOnIdle { width=size; scale=1f }; rule.waitForIdle()
            val like=rule.onNodeWithTag("like").getUnclippedBoundsInRoot(); val coin=rule.onNodeWithTag("coin").getUnclippedBoundsInRoot(); val favorite=rule.onNodeWithTag("favorite").getUnclippedBoundsInRoot()
            val spacing=52f+((size-268f)/3).coerceIn(4f,24f)
            assertEquals(spacing,(coin.left-like.left).value,.5f); assertEquals(spacing,(favorite.left-coin.left).value,.5f)
            val share=rule.onNodeWithTag("share").getUnclippedBoundsInRoot(); val download=rule.onNodeWithTag("download").getUnclippedBoundsInRoot()
            assertTrue(share.left>=favorite.right); assertTrue(download.left>=share.right)
            assertTrue(download.right.value<=size+.5f)
            assertTrue((like.bottom-like.top).value>=57.5f); assertEquals(like.top, favorite.top)
        }
        rule.runOnIdle { width=288; scale=2f }; rule.waitForIdle()
        val like=rule.onNodeWithTag("like").getUnclippedBoundsInRoot(); val favorite=rule.onNodeWithTag("favorite").getUnclippedBoundsInRoot()
        assertTrue(favorite.top>=like.bottom); assertTrue((like.right-like.left).value>=140)
        val share=rule.onNodeWithTag("share").getUnclippedBoundsInRoot(); val download=rule.onNodeWithTag("download").getUnclippedBoundsInRoot()
        assertEquals(share.left.value,download.left.value,.5f); assertTrue(download.top>=share.bottom)
    }
}

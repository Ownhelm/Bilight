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
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class LayoutRegressionTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()
    @Test fun actionSpacingAndLargeFontFallbackUseTheActualSharedLayout() {
        rule.runOnUiThread { rule.activity.findViewById<ViewGroup>(android.R.id.content).removeAllViews() }
        var width by mutableIntStateOf(288); var scale by mutableFloatStateOf(1f)
        rule.setContent {
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density,scale)) {
                Box(Modifier.width(width.dp)) {
                    ActionBarLayout(like={ Text("赞",it.heightIn(min=58.dp).testTag("like")) },coin={ Text("币",it.heightIn(min=58.dp).testTag("coin")) },favorite={ Text("藏",it.heightIn(min=58.dp).testTag("favorite")) },download={ Text("下载",it.heightIn(min=58.dp).testTag("download")) })
                }
            }
        }
        for (size in listOf(288,343,358,398,408)) {
            rule.runOnIdle { width=size; scale=1f }; rule.waitForIdle()
            val like=rule.onNodeWithTag("like").getUnclippedBoundsInRoot(); val coin=rule.onNodeWithTag("coin").getUnclippedBoundsInRoot(); val favorite=rule.onNodeWithTag("favorite").getUnclippedBoundsInRoot()
            assertEquals(76f,(coin.left-like.left).value,.5f); assertEquals(76f,(favorite.left-coin.left).value,.5f)
            assertTrue((like.bottom-like.top).value>=57.5f); assertEquals(like.top, favorite.top)
        }
        rule.runOnIdle { width=288; scale=2f }; rule.waitForIdle()
        val like=rule.onNodeWithTag("like").getUnclippedBoundsInRoot(); val favorite=rule.onNodeWithTag("favorite").getUnclippedBoundsInRoot()
        assertTrue(favorite.top>=like.bottom); assertTrue((like.right-like.left).value>=140)
    }
}

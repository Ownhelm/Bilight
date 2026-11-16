package app.bilight.android

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import app.bilight.android.core.Folder
import app.bilight.android.ui.FavoriteSheet
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** Local UI state only: no account, repository or interaction writes. */
class FavoriteSheetTest {
    @get:Rule val rule=createAndroidComposeRule<ComponentActivity>()

    @Test fun loadingErrorAndFolderListsKeepTheSameSheetHeight() {
        var folders by mutableStateOf<List<Folder>?>(null)
        var error by mutableStateOf<String?>(null)
        rule.setContent {
            MaterialTheme { FavoriteSheet(folders,emptySet(),error,false,{},{},{},{},retry={ error=null }) }
        }
        fun positions() = listOf("收藏到（0）","确定").map { label ->
            rule.onNodeWithText(label).fetchSemanticsNode().boundsInWindow.top
        }
        val initial=positions()
        rule.runOnIdle { error="收藏夹读取超时" }
        rule.onNodeWithText("收藏夹读取超时").assertIsDisplayed()
        assertEquals("The error must not move the header or buttons",initial,positions())
        rule.onNodeWithText("重试").performClick()
        rule.onNodeWithText("正在读取收藏夹").assertIsDisplayed()
        assertEquals("Retry must use the same sheet",initial,positions())

        rule.runOnIdle { folders=listOf(Folder(1,1,"默认收藏夹",0,false)) }
        val folderTitle=rule.onNodeWithText("默认收藏夹",useUnmergedTree=true).assertIsDisplayed()
        val createLabel=rule.onNodeWithText("新建收藏夹",useUnmergedTree=true).assertIsDisplayed()
        val labelIndent=(createLabel.getUnclippedBoundsInRoot().left-folderTitle.getUnclippedBoundsInRoot().left).value
        assertEquals("Only the 20 dp icon and 8 dp gap should precede the label",28f,labelIndent,1f)
        assertEquals("A short list must not move the header or buttons",initial,positions())

        rule.runOnIdle { folders=(1L..40L).map { Folder(it,1,"收藏夹 $it",0,false) } }
        rule.onNodeWithText("收藏夹 40").performScrollTo().assertIsDisplayed()
        assertEquals("A long list must scroll inside the same sheet",initial,positions())
    }

    @Test fun longListScrollsBothWaysAndKeepsConfirmationVisible() {
        var folders by mutableStateOf((1L..40L).map { Folder(it,1,"收藏夹 $it",0,false,selected=it==1L) })
        var selected by mutableStateOf(setOf(1L))
        var confirmations=0
        rule.setContent {
            MaterialTheme {
                FavoriteSheet(folders,selected,null,false,{ selected=it },{},{ confirmations++ },{ title ->
                    folders=folders+Folder(41,1,title,0,false)
                    selected=selected+41L
                })
            }
        }
        rule.onNodeWithText("确定").assertIsDisplayed().assertIsNotEnabled()
        rule.onNodeWithText("收藏夹 40").performScrollTo().assertIsDisplayed().performClick()
        rule.onNodeWithText("确定").assertIsDisplayed().assertIsEnabled()
        rule.runOnIdle { assertEquals(setOf(1L,40L),selected) }
        val entry=rule.onNode(hasText("新建收藏夹") and hasClickAction())
        val field=rule.onNode(hasSetTextAction())
        val create=rule.onNodeWithText("创建")
        field.assertDoesNotExist()
        entry.performScrollTo().performClick()
        create.assertIsDisplayed().assertIsNotEnabled()
        field.performTextInput("新收藏夹")
        rule.onNode(hasText("取消") and hasAnyAncestor(isDialog() and hasAnyDescendant(hasText("创建")))).performClick()
        field.assertDoesNotExist()
        rule.runOnIdle { assertEquals(setOf(1L,40L),selected) }

        entry.performScrollTo().performClick()
        create.assertIsNotEnabled()
        field.performTextInput("新收藏夹")
        create.performClick()
        field.assertDoesNotExist()
        rule.onNodeWithText("新收藏夹").performScrollTo().assertIsOn()
        rule.runOnIdle { assertEquals(0,confirmations) }
        rule.onNodeWithText("收藏夹 1").performScrollTo().assertIsDisplayed().performClick()
        rule.runOnIdle { assertEquals(setOf(40L,41L),selected) }
        rule.onNodeWithText("确定").assertIsDisplayed()
    }

    @Test fun fullFoldersCannotBeAddedAndClearAllIsAnExplicitChange() {
        val folders=listOf(Folder(1,1,"已经收藏",1000,true,true),Folder(2,1,"已满未收藏",1000,false))
        var selected by mutableStateOf(setOf(1L))
        rule.setContent {
            MaterialTheme { FavoriteSheet(folders,selected,null,false,{ selected=it },{},{},{}) }
        }
        rule.onNodeWithText("已满未收藏").assertIsNotEnabled()
        rule.onNodeWithText("取消全部").performClick()
        rule.runOnIdle { assertEquals(emptySet<Long>(),selected) }
        rule.onNodeWithText("确定").assertIsEnabled()
    }
}

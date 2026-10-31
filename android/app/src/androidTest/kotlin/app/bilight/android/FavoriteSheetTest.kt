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

    @Test fun longListScrollsBothWaysAndKeepsConfirmationVisible() {
        val folders=(1L..40L).map { Folder(it,1,"收藏夹 $it",0,false,selected=it==1L) }
        var selected by mutableStateOf(setOf(1L))
        var title by mutableStateOf("")
        rule.setContent {
            MaterialTheme {
                FavoriteSheet(folders,selected,null,title,false,{ selected=it },{ title=it },{},{},{})
            }
        }
        rule.onNodeWithText("确定").assertIsDisplayed().assertIsNotEnabled()
        rule.onNodeWithText("收藏夹 40").performScrollTo().assertIsDisplayed().performClick()
        rule.onNodeWithText("确定").assertIsDisplayed().assertIsEnabled()
        rule.runOnIdle { assertEquals(setOf(1L,40L),selected) }
        rule.onNode(hasSetTextAction()).performScrollTo().performTextInput("新收藏夹")
        rule.onNodeWithText("新建并勾选").performScrollTo().assertIsDisplayed()
        rule.onNodeWithText("收藏夹 1").performScrollTo().assertIsDisplayed().performClick()
        rule.runOnIdle { assertEquals(setOf(40L),selected) }
        rule.onNodeWithText("确定").assertIsDisplayed()
    }

    @Test fun fullFoldersCannotBeAddedAndClearAllIsAnExplicitChange() {
        val folders=listOf(Folder(1,1,"已经收藏",1000,true,true),Folder(2,1,"已满未收藏",1000,false))
        var selected by mutableStateOf(setOf(1L))
        rule.setContent {
            MaterialTheme { FavoriteSheet(folders,selected,null,"",false,{ selected=it },{},{},{},{}) }
        }
        rule.onNodeWithText("已满未收藏").assertIsNotEnabled()
        rule.onNodeWithText("取消全部").performClick()
        rule.runOnIdle { assertEquals(emptySet<Long>(),selected) }
        rule.onNodeWithText("确定").assertIsEnabled()
    }
}

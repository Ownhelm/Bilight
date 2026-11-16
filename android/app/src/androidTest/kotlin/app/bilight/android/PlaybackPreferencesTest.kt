package app.bilight.android

import android.content.Context
import android.content.Intent
import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.graphics.Rect
import android.os.SystemClock
import android.os.Bundle
import android.view.MotionEvent
import android.view.ViewGroup
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.text.input.TextFieldValue
import app.bilight.android.ui.MainApp
import app.bilight.android.ui.CommentComposerSheet
import app.bilight.android.ui.CommentDraft
import app.bilight.android.ui.VideoCommentComposerState
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.*
import app.bilight.android.core.Route
import app.bilight.android.playback.PlaybackModel
import app.bilight.android.playback.PlaybackSettings
import app.bilight.android.downloads.DownloadRecord
import app.bilight.android.downloads.DownloadState
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream

/** Exercise persisted device preferences through real PlaybackModel instances, with no platform calls. */
class PlaybackPreferencesTest {
    private val activity=ActivityScenarioRule(MainActivity::class.java)
    @get:Rule val activityLaunch=org.junit.rules.TestRule { statement,description ->
        if (description.methodName in setOf(
            "progressiveMp4StartsWithARangeOnCdnsThatRejectWholeFileRequests",
            "captionsSpeedAndDanmakuFollowExplicitChoicesAcrossVideosAndRecreatedPlayers",
            "explicitQualitySurvivesNewPlayersAndUnavailableQualityDoesNotReplaceIt",
            "danmakuPreferencesPersistAndStyleChangesOrCancelledReadsCannotRefetchOrResurrectIt",
        )) statement else activity.apply(statement,description)
    }
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private fun main(block: () -> Unit)=instrumentation.runOnMainSync(block)
    private fun await(message: String,condition: () -> Boolean) {
        var done=false; val deadline=android.os.SystemClock.elapsedRealtime()+7000
        while (!done && android.os.SystemClock.elapsedRealtime()<deadline) {
            main { done=condition() }; if (!done) Thread.sleep(20)
        }
        assertTrue(message,done)
    }
    private fun fixture(durationSeconds: Int = 1, audio: Boolean = false, authenticated: Boolean = false, test: (Fixture) -> Unit) {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        val isolatedDeviceBuild=app.packageName=="app.bilight.android.awakeverification"
        check((android.os.Build.HARDWARE in listOf("ranchu","goldfish") || isolatedDeviceBuild) && SessionVault(app).load()==null) { "Use only an isolated anonymous emulator or the separate device verification app" }
        val store=app.getSharedPreferences("playback-preferences",Context.MODE_PRIVATE)
        val saved=HashMap(store.all)
        store.edit().clear().commit()
        val fixture=Fixture(app,durationSeconds,audio,authenticated)
        try { test(fixture) } finally {
            fixture.close()
            store.edit().clear().apply {
                saved.forEach { (key,value) -> when (value) {
                    is Boolean -> putBoolean(key,value); is Int -> putInt(key,value); is Float -> putFloat(key,value)
                    is Long -> putLong(key,value); is String -> putString(key,value)
                } }
            }.commit()
        }
    }
    @Test fun cachedPlaybackKeepsTheNormalActionsAndLoadsCommentsWhenNetworkReturns() = fixture(30,authenticated=true) { f ->
        val route=f.cachedVideo()
        fun shell(command: String) { android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use { it.readBytes() } }
        lateinit var model: PlaybackModel
        try {
            shell("svc wifi disable"); shell("svc data disable")
            await("The isolated device did not finish disconnecting") {
                val connectivity=f.app.getSystemService(android.net.ConnectivityManager::class.java)
                connectivity.getNetworkCapabilities(connectivity.activeNetwork)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)!=true
            }
            main { model=f.owner.playback(route); f.owner.open(route) }
            activity.scenario.onActivity { it.setContent { MainApp(f.owner) } }
            await("A cached file must play without any network") { !model.networkAvailable && model.player.isPlaying }
            val player=model.player
            lateinit var item: androidx.media3.common.MediaItem
            main {
                item=player.currentMediaItem!!
                assertEquals("file",item.localConfiguration!!.uri.scheme)
                assertFalse(model.detailLoaded); assertTrue(model.videoComments.comments.isEmpty())
                player.pause(); model.seek(500); model.speed(1.5f)
            }
            shell("svc wifi enable"); shell("svc data enable")
            await("Reconnecting did not load cached-video metadata and comments") { model.networkAvailable && model.detailLoaded && model.videoComments.comments.singleOrNull()?.text=="缓存页评论测试" && model.engagement!=null }
            main {
                assertSame(player,model.player); assertEquals(item,player.currentMediaItem)
                assertFalse(player.playWhenReady); assertEquals(1.5f,player.playbackParameters.speed)
                assertEquals(500.0,player.currentPosition.toDouble(),150.0)
            }
            // Read only this isolated app's accessibility tree; never trigger a real interaction write.
            fun labels(node: android.view.accessibility.AccessibilityNodeInfo?): List<String> {
                if (node==null) return emptyList()
                return listOfNotNull(node.text?.toString(),node.contentDescription?.toString())+(0 until node.childCount).flatMap { labels(node.getChild(it)) }
            }
            instrumentation.waitForIdleSync(); Thread.sleep(300)
            val visible=labels(instrumentation.uiAutomation.rootInActiveWindow)
            File(f.app.getExternalFilesDir(null),"cached-player-labels.txt").writeText(visible.joinToString("\n"))
            instrumentation.uiAutomation.takeScreenshot()?.let { image ->
                File(f.app.getExternalFilesDir(null),"cached-player.png").outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }
            }
            assertTrue("The cached action must remain visible",visible.any { it.contains("已缓存") })
            assertTrue("The standard share action must remain visible",visible.any { it.contains("转发") })
            assertFalse(visible.any { it.contains("导出 MP4") })
        } finally { shell("svc wifi enable"); shell("svc data enable") }
    }
    @Test fun videoPageKeepsTheDisplayAwakeAndReleasesItOnPauseEndAndExit() = fixture(30,audio=false) { f ->
        lateinit var model: PlaybackModel
        lateinit var screen: MainActivity
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")); f.owner.open(model.route) }
        activity.scenario.onActivity {
            screen=it
            it.findViewById<ViewGroup>(android.R.id.content).removeAllViews()
            it.setContent { MainApp(f.owner) }
        }
        fun keepsAwake(view: android.view.View): Boolean {
            if (view.keepScreenOn) return true
            if (view is ViewGroup) for (index in 0 until view.childCount) if (keepsAwake(view.getChildAt(index))) return true
            return false
        }
        fun awake()=keepsAwake(screen.findViewById(android.R.id.content))
        await("The real playing video page did not request screen-on") { model.player.isPlaying && awake() }
        for (fullscreen in listOf(false,true)) {
            main { model.fullscreen=fullscreen; model.portraitFullscreen=fullscreen }
            await("Changing fullscreen lost the screen-on request") { awake() }
            main { model.player.pause() }
            await("Pausing kept the display awake") { !awake() }
            main { model.player.play() }
            await("Resuming did not restore the screen-on request") { model.player.isPlaying && awake() }
        }
        activity.scenario.moveToState(androidx.lifecycle.Lifecycle.State.STARTED)
        await("A background page kept the display awake") { !awake() }
        activity.scenario.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
        await("Returning did not restore screen-on for ongoing playback") { model.player.isPlaying && awake() }
        main { model.player.seekTo(model.player.duration-100); model.player.play() }
        await("Ending did not release the display") { model.player.playbackState==androidx.media3.common.Player.STATE_ENDED && !awake() }
        main { model.toggle() }
        await("Replaying did not restore screen-on") { model.player.isPlaying && awake() }
        main { f.owner.back() }
        await("Leaving the page did not release screen-on") { !awake() }
    }

    @Test fun lockScreenSessionPublishesMetadataAndControlsTheExistingPlayer() = fixture(30,audio=true) { f ->
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")); model.enableBackgroundPlayback() }
        await("Media did not start") { model.player.isPlaying }
        val notifications=f.app.getSystemService(NotificationManager::class.java)
        await("No system media notification was published") { notifications.activeNotifications.any { it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) } }
        val notification=notifications.activeNotifications.first { it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) }.notification
        assertEquals("The media card must be visible on the lock screen",Notification.VISIBILITY_PUBLIC,notification.visibility)
        val token=notification.extras.getParcelable(Notification.EXTRA_MEDIA_SESSION,MediaSession.Token::class.java)!!
        val controller=MediaController(f.app,token)
        assertEquals("A lock-screen card must identify the current video","偏好恢复测试",controller.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE))
        assertEquals("隔离测试",controller.metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST))
        val state=controller.playbackState!!
        assertEquals(0L,state.actions and (PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_SKIP_TO_NEXT))
        val (back,forward)=state.customActions
        val seekIcons=listOf("media3_icon_skip_back_10","media3_icon_skip_forward_10")
        assertEquals(seekIcons,state.customActions.map { f.app.resources.getResourceEntryName(it.icon) })
        assertEquals(seekIcons,listOf(notification.actions.first(),notification.actions.last())
            .map { f.app.resources.getResourceEntryName(it.getIcon().resId) })
        check(!f.app.getSystemService(KeyguardManager::class.java).isDeviceSecure)
        main { model.background() }
        instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)
        instrumentation.uiAutomation.executeShellCommand("input keyevent 223").close()
        controller.transportControls.pause()
        await("System pause did not pause the actual player") { !model.player.playWhenReady }
        controller.transportControls.seekTo(2000)
        await("System seek did not update the actual player") { kotlin.math.abs(model.player.currentPosition-2000)<250 }
        controller.transportControls.sendCustomAction(forward,null)
        await("The card did not jump forward ten seconds") { kotlin.math.abs(model.player.currentPosition-12000)<250 }
        controller.transportControls.sendCustomAction(back,null)
        await("The card did not jump back ten seconds") { kotlin.math.abs(model.player.currentPosition-2000)<250 }
        controller.transportControls.sendCustomAction(back,null)
        await("The card must stop at the start of the video") { model.player.currentPosition==0L }
        main { assertFalse("Seeking a paused item must keep it paused",model.player.playWhenReady) }
        controller.transportControls.play()
        await("System play did not resume the same player") { model.player.isPlaying }
        instrumentation.uiAutomation.executeShellCommand("input keyevent 224").close()
        assertTrue(controller.playbackState!!.actions and PlaybackState.ACTION_SEEK_TO != 0L)
        main { model.close() }
        await("Closing playback must remove the media notification") { notifications.activeNotifications.none { it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) } }
    }
    @Test fun temporarySpeedAndBackgroundAudioPreserveTheSamePlayerAndUserPause() = fixture(8,audio=true) { f ->
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("The background audio fixture did not prepare") { model.playback!=null && !model.preparing }
        val player=model.player
        main {
            player.pause(); model.speed(1.5f); model.beginTemporarySpeed()
            assertFalse(player.playWhenReady); assertEquals(1.5f,player.playbackParameters.speed)
            model.enableBackgroundPlayback(); player.play()
        }
        await("The fixture must really be playing") { player.isPlaying }
        main { f.owner.open(model.route) }
        activity.scenario.onActivity { screen ->
            screen.findViewById<ViewGroup>(android.R.id.content).removeAllViews()
            screen.setContent { MainApp(f.owner) }
        }
        fun findNode(node: android.view.accessibility.AccessibilityNodeInfo?, matches: (android.view.accessibility.AccessibilityNodeInfo) -> Boolean): android.view.accessibility.AccessibilityNodeInfo? {
            if (node==null || matches(node)) return node
            for (i in 0 until node.childCount) findNode(node.getChild(i), matches)?.let { return it }
            return null
        }
        fun videoBounds(): Rect {
            val deadline=SystemClock.elapsedRealtime()+3000
            while (SystemClock.elapsedRealtime()<deadline) {
                val node=findNode(instrumentation.uiAutomation.rootInActiveWindow) { it.contentDescription?.toString()=="视频画面" }
                val bounds=Rect().also { node?.getBoundsInScreen(it) }
                if (!bounds.isEmpty) return bounds
                Thread.sleep(30)
            }
            error("The actual video surface was not accessible")
        }
        for (fullscreen in listOf(false,true)) {
            main { model.fullscreen=fullscreen; model.portraitFullscreen=fullscreen; model.controlsVisible=false; model.seek(0); player.play() }
            instrumentation.waitForIdleSync()
            val bounds=videoBounds(); val down=SystemClock.uptimeMillis()
            fun touch(action: Int) {
                val event=MotionEvent.obtain(down,SystemClock.uptimeMillis(),action,bounds.exactCenterX(),bounds.exactCenterY(),0)
                try { check(instrumentation.uiAutomation.injectInputEvent(event,true)) } finally { event.recycle() }
            }
            touch(MotionEvent.ACTION_DOWN)
            try {
                Thread.sleep(650)
                main { assertEquals("The actual held surface did not accelerate (fullscreen=$fullscreen)",2f,player.playbackParameters.speed) }
                assertNull("Holding for 2× speed must not show a center banner", findNode(instrumentation.uiAutomation.rootInActiveWindow) { it.text?.toString()=="2× 倍速" })
            }
            finally { touch(MotionEvent.ACTION_UP) }
            Thread.sleep(80); main { assertEquals(1.5f,player.playbackParameters.speed) }
        }
        main {
            model.beginTemporarySpeed(); assertEquals(2f,player.playbackParameters.speed); assertEquals(1.5f,model.speed)
            model.endTemporarySpeed(); assertEquals(1.5f,player.playbackParameters.speed)
            model.seek(0); player.play()
            model.background()
        }
        val manager=f.app.getSystemService(ActivityManager::class.java)
        @Suppress("DEPRECATION")
        await("Media playback must be hosted by a foreground service") { manager.getRunningServices(100).any { it.service.className.endsWith(".PlaybackService") && it.foreground } }
        check(!f.app.getSystemService(KeyguardManager::class.java).isDeviceSecure)
        instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)
        var before=0L; main { before=player.currentPosition }
        try {
            instrumentation.uiAutomation.executeShellCommand("input keyevent 223").close()
            Thread.sleep(500)
            main { assertSame(player,model.player); assertTrue(player.playWhenReady); assertTrue("Audio stopped after Home and screen off",player.currentPosition>before+100); player.pause() }
        } finally {
            instrumentation.uiAutomation.executeShellCommand("input keyevent 224").close()
            instrumentation.uiAutomation.executeShellCommand("wm dismiss-keyguard").close()
            f.app.startActivity(Intent(f.app,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        main { model.foreground(); assertFalse("Foregrounding cannot undo a pause made while hidden",player.playWhenReady); assertSame(player,model.player) }
    }
    @Test fun interactionCountsUpdateBeforeConfirmationAndRollBackOnFailure() = fixture(authenticated=true) { f ->
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("The initial account engagement did not load") { model.engagement!=null }
        val before=model.engagement!!
        val totals=model.statistics!!
        val actions=listOf(
            VideoWrite.Like(true) to Statistics(1,0,0),
            VideoWrite.Coin(2,true) to Statistics(1,2,0),
            VideoWrite.Favorite(setOf(1L,2L)) to Statistics(0,0,1),
            VideoWrite.Triple to Statistics(1,1,1)
        )
        for ((action,expected) in actions) {
            f.engagementGate=CountDownLatch(1); f.failEngagement=true
            main {
                model.write(action)
                assertEquals(expected,model.statistics)
                assertEquals(expected.likes>0,model.engagement!!.liked)
                assertEquals(expected.coins.toInt(),model.engagement!!.coins)
                assertEquals(expected.favorites>0,model.engagement!!.favorite)
            }
            f.engagementGate!!.countDown()
            await("The failed operation did not finish") { !model.actionBusy }
            main {
                assertEquals(before,model.engagement); assertEquals(totals,model.statistics)
                if (action is VideoWrite.Favorite) assertNotNull(model.supportError) else assertNull(model.supportError)
            }
        }
    }
    @Test fun confirmedLikeKeepsItsCountWithoutRequiringPublicTotals() = fixture(authenticated=true) { f ->
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("The initial account engagement did not load") { model.engagement!=null && model.detailLoaded }
        val reads=f.detailReads.get()
        f.detailGate=CountDownLatch(1)
        try {
            main { model.write(VideoWrite.Like(true)) }
            await("The confirmed like must unlock coin and favorite") { f.likePosts.get()==1 && !model.actionBusy }
            main { assertTrue(model.engagement!!.liked); assertEquals(1L,model.statistics!!.likes) }
            main { model.write(VideoWrite.Like(true)) }
            await("The repeated like should finish without another write") { !model.actionBusy }
            main { assertEquals(1L,model.statistics!!.likes) }
            assertEquals(reads,f.detailReads.get())
            assertEquals("The like must only be submitted once",1,f.likePosts.get())
        } finally { f.detailGate!!.countDown() }
    }
    @Test fun commentInteractionShowsPendingLikeAndPreservesRejectedDraft() = fixture(authenticated=true) { f ->
        f.seedVideoComment=true
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("The isolated video comment did not load") { model.videoComments.comments.size==1 }
        val comment=model.videoComments.comments.single()
        f.commentLikeGate=CountDownLatch(1)
        f.rejectCommentWrites=true
        try {
            main {
                model.videoComments.toggleCommentLike(comment)
                assertTrue(model.videoComments.commentLikePending(comment))
                assertEquals(CommentLikeState(true,5),model.videoComments.commentLike(comment))
            }
        } finally { f.commentLikeGate!!.countDown() }
        await("Rejected comment like did not settle") { model.videoComments.commentLikeErrors[comment.id]!=null && !model.videoComments.commentLikePending(comment) }
        main { assertEquals(CommentLikeState(false,4),model.videoComments.commentLike(comment)) }
        val message="隔离评论正文"
        val composer=VideoCommentComposerState()
        main {
            composer.open(null); composer.draft=CommentDraft(TextFieldValue(message))
            model.videoComments.sendComment(composer.draft.field.text,emptyList(),null,composer::sent)
        }
        await("Rejected comment send did not settle") { model.videoComments.commentSendError!=null && !model.videoComments.commentSending }
        main {
            assertTrue(composer.visible)
            assertEquals(message,composer.draft.field.text)
            assertEquals(listOf(comment.id),model.videoComments.comments.map { it.id })
        }
        f.rejectCommentWrites=false
        f.unconfirmedCommentWrite=true
        main { model.videoComments.sendComment(composer.draft.field.text,emptyList(),null,composer::sent) }
        await("Incomplete publish response did not require a refresh") { model.videoComments.commentSendNeedsRefresh && !model.videoComments.commentSending }
        main {
            assertTrue(composer.visible)
            assertEquals(message,composer.draft.field.text)
            model.videoComments.sendComment(composer.draft.field.text,emptyList(),null,composer::sent)
            assertFalse(model.videoComments.commentSending)
            model.videoComments.refreshComments()
        }
        await("The comments were not refreshed") { !model.videoComments.commentSendNeedsRefresh }
        f.unconfirmedCommentWrite=false
        main { model.videoComments.sendComment(composer.draft.field.text,emptyList(),null,composer::sent) }
        await("Confirmed comment did not appear") { model.videoComments.comments.firstOrNull()?.id=="17" }
        main { assertFalse(composer.visible); assertEquals("",composer.draft.field.text); assertEquals(message,model.videoComments.comments.first().text) }
        assertEquals(1,f.commentLikeWrites.get())
        assertEquals(3,f.commentPosts.get())
    }
    @Test fun commentComposerKeepsSendAccessibleWhileSelectingAMention() = fixture(authenticated=true) { f ->
        lateinit var model: PlaybackModel
        val composer=VideoCommentComposerState()
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("The test video did not load") { model.detailLoaded }
        main { composer.open(null) }
        activity.scenario.onActivity { screen ->
            screen.findViewById<ViewGroup>(android.R.id.content).removeAllViews()
            screen.setContent { MaterialTheme { if (composer.visible) CommentComposerSheet(model.videoComments,composer) } }
        }
        val automation=instrumentation.uiAutomation
        automation.serviceInfo=automation.serviceInfo.apply { flags=flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS }
        fun find(node: android.view.accessibility.AccessibilityNodeInfo?,test: (android.view.accessibility.AccessibilityNodeInfo) -> Boolean): android.view.accessibility.AccessibilityNodeInfo? {
            if (node==null) return null
            if (node.isVisibleToUser && test(node)) return node
            for (index in 0 until node.childCount) find(node.getChild(index),test)?.let { return it }
            return null
        }
        fun findInApp(test: (android.view.accessibility.AccessibilityNodeInfo) -> Boolean) =
            (listOfNotNull(automation.rootInActiveWindow)+automation.windows.mapNotNull { it.root })
                .filter { it.packageName==f.app.packageName }.firstNotNullOfOrNull { find(it,test) }
        fun visibleNode(text: String) = findInApp { it.text?.contains(text)==true || it.contentDescription?.contains(text)==true }
        fun findEditor(): android.view.accessibility.AccessibilityNodeInfo {
            val deadline=SystemClock.elapsedRealtime()+7000
            while (SystemClock.elapsedRealtime()<deadline) {
                findInApp { it.isEditable }?.let { return it }
                Thread.sleep(30)
            }
            error("The comment editor was not visible")
        }
        findEditor()
        assertNull("The composer must not have a standalone mention button",findInApp { it.text?.toString()=="@" })
        assertEquals(0,f.commentMentionReads.get())
        fun input(value: String) {
            assertTrue(findEditor().performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_TEXT,Bundle().apply {
                putCharSequence(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,value)
            }))
        }
        input("＠")
        await("Bare @ did not fetch the default Bilibili candidates") { f.commentMentionReads.get()==1 }
        input("＠隔离")
        val deadline=SystemClock.elapsedRealtime()+7000
        var scrolled=false
        while ((f.commentMentionReads.get()<2 || visibleNode("隔离候选1")==null || visibleNode("发送评论")==null) && SystemClock.elapsedRealtime()<deadline) {
            if (f.commentMentionReads.get()==2 && !scrolled && visibleNode("发送")!=null) {
                scrolled=findInApp { it.isScrollable }
                    ?.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)==true
            }
            Thread.sleep(30)
        }
        val candidate=checkNotNull(visibleNode("隔离候选1")) { "The first mention candidate was not reachable" }
        assertEquals(2,f.commentMentionReads.get())
        assertNotNull("The Send action must remain visible while suggestions are shown",visibleNode("发送评论"))
        val control=generateSequence(candidate) { it.parent }.first { it.isClickable }
        assertTrue(control.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
        await("The selected mention was not inserted into the draft") { composer.draft.field.text=="@隔离候选1 " }
        main { assertEquals(1L,composer.draft.users.single().mid); composer.close() }
    }
    @Test fun sectionExpansionPersistsIndependentlyAcrossFreshPlaybackModels() = fixture { f ->
        main {
            val first=f.owner.playback(Route.Watch("BV12qnt6VEM1"))
            assertTrue(first.commentsExpanded)
            assertFalse(first.descriptionExpanded)
            first.toggleDescriptionExpanded()
            assertTrue(first.commentsExpanded)
            assertTrue(PlaybackSettings(f.app).descriptionExpanded)
            first.toggleCommentsExpanded()
            assertFalse(PlaybackSettings(f.app).commentsExpanded)
            f.owner.releasePlayback(first)
            val second=f.owner.playback(Route.Watch("BV1NGZtBwELa"))
            assertFalse(second.commentsExpanded)
            assertTrue(second.descriptionExpanded)
            second.toggleCommentsExpanded()
            second.toggleDescriptionExpanded()
            assertTrue(PlaybackSettings(f.app).commentsExpanded)
            assertFalse(PlaybackSettings(f.app).descriptionExpanded)
            f.owner.releasePlayback(second)
            val reopened=f.owner.playback(Route.Watch("BV12qnt6VEM1"))
            assertTrue(reopened.commentsExpanded)
            assertFalse(reopened.descriptionExpanded)
        }
    }
    @Test fun captionsSpeedAndDanmakuFollowExplicitChoicesAcrossVideosAndRecreatedPlayers() = fixture(8) { f ->
        lateinit var model: PlaybackModel
        fun open(bvid: String) {
            main { model=f.owner.playback(Route.Watch(bvid)) }
            await("Subtitle metadata did not load") { model.tracks.size==f.languages.size && !model.preparing }
        }
        open("BV12qnt6VEM1")
        await("Default captions did not load") { model.cues.isNotEmpty() }
        main {
            model.subtitle(model.tracks.first { it.language=="en" }); model.speed(1.5f)
            model.danmaku(true); model.font(24); model.area(.5f); model.opacity(.75f)
        }
        await("Selected captions did not load") { model.cues.isNotEmpty() && model.player.isPlaying }
        main {
            model.beginTemporarySpeed(); assertEquals(2f,model.player.playbackParameters.speed)
            assertEquals(1.5f,PlaybackSettings(f.app).speed)
            f.owner.releasePlayback(model)
        }
        open("BV1NGZtBwELa")
        await("The language preference was not restored with different track IDs") { model.subtitle?.language=="en" && model.cues.isNotEmpty() }
        main {
            assertEquals(1.5f,model.speed); assertEquals(1.5f,model.player.playbackParameters.speed)
            assertTrue(model.danmaku); assertEquals(24,model.danmakuFont); assertEquals(.5f,model.danmakuArea); assertEquals(.75f,model.danmakuOpacity)
            model.subtitle(null); model.danmaku(false)
            model.selectPart(model.detail!!.parts[1])
        }
        await("Next part metadata did not arrive") { model.part?.cid==44L && model.tracks.isNotEmpty() && !model.preparing }
        main { assertNull(model.subtitle); assertTrue(model.cues.isEmpty()); f.owner.releasePlayback(model) }
        f.languages=emptyList()
        open("BV12qnt6VEM1")
        main { assertNull(model.subtitle); assertFalse(PlaybackSettings(f.app).subtitlesEnabled); f.owner.releasePlayback(model) }
        f.languages=listOf("zh-CN", "en")
        open("BV1NGZtBwELa")
        main {
            assertNull(model.subtitle); assertTrue(model.cues.isEmpty()); assertFalse(model.danmaku)
            assertFalse(PlaybackSettings(f.app).subtitlesEnabled)
            model.subtitle(model.tracks.first { it.language=="en" }); f.owner.releasePlayback(model)
        }
        f.languages=listOf("zh-CN")
        open("BV12qnt6VEM1")
        await("Unavailable language did not temporarily fall back") { model.subtitle?.language=="zh-CN" }
        main { assertEquals("en",PlaybackSettings(f.app).subtitleLanguage); f.owner.releasePlayback(model) }
        f.languages=listOf("zh-CN", "en")
        open("BV1NGZtBwELa")
        await("Preferred language was overwritten by a fallback") { model.subtitle?.language=="en" }
        main { f.owner.releasePlayback(model) }
        f.subtitleGate=CountDownLatch(1)
        val before=f.subtitleReads.get()
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("Delayed metadata request did not start") { f.subtitleReads.get()>before }
        main { model.subtitle(null) }
        f.subtitleGate!!.countDown()
        await("Disabling while metadata loads discarded the track list") { model.tracks.isNotEmpty() }
        main { assertNull(model.subtitle); assertTrue(model.cues.isEmpty()); assertFalse(PlaybackSettings(f.app).subtitlesEnabled) }
    }

    @Test fun explicitQualitySurvivesNewPlayersAndUnavailableQualityDoesNotReplaceIt() = fixture { f ->
        val preferences=PlaybackSettings(f.app)
        fun open(bvid: String): PlaybackModel {
            lateinit var model: PlaybackModel
            main { model=f.owner.playback(Route.Watch(bvid)) }
            await("The fixture video did not finish preparing") { model.playback!=null && !model.preparing }
            main { assertNull(model.error); model.player.pause() }
            return model
        }
        val high="BV12qnt6VEM1"; val low="BV1NGZtBwELa"
        val first=open(high)
        main {
            assertEquals(120,first.playback!!.quality)
            assertEquals("An automatic selection overwrote the preference",127,preferences.quality)
            first.chooseQuality(120); assertEquals(120,preferences.quality)
        }
        val lower=open(low)
        main {
            assertEquals(80,lower.playback!!.quality)
            assertEquals("Fallback replaced the preferred higher quality",120,preferences.quality)
            lower.chooseQuality(120); assertEquals(120,preferences.quality)
        }
        val restored=open(high)
        main { assertEquals("The original quality was not restored",120,restored.playback!!.quality) }
        val selectedLower=open(low)
        main { selectedLower.chooseQuality(80); assertEquals(80,PlaybackSettings(f.app).quality) }
        val last=open(high)
        main { assertEquals(80,last.playback!!.quality) }
        assertEquals(listOf(127,120,120,120,80),f.requestedQualities.toList())
    }
    @Test fun danmakuPreferencesPersistAndStyleChangesOrCancelledReadsCannotRefetchOrResurrectIt() = fixture { f ->
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("Initial subtitles were not selected") { model.cues.isNotEmpty() }
        main { assertFalse(model.danmaku); assertEquals("zh-CN",model.subtitle!!.language) }
        assertEquals(0,f.danmakuReads.get())
        main { model.danmaku(true) }
        await("Compressed comments were not loaded") { model.danmakuItems.isNotEmpty() }
        assertEquals(1,f.danmakuReads.get())
        main {
            model.font(24); model.area(.5f); model.opacity(.75f)
            model.subtitle(null); assertTrue(model.cues.isEmpty()); assertEquals("",model.subtitleText)
        }
        Thread.sleep(150)
        assertEquals("A style change refetched comments",1,f.danmakuReads.get())
        val samePlayer=model.player
        main { model.selectPart(model.detail!!.parts[1]) }
        await("The second part did not replace the old comments") { model.danmakuItems.singleOrNull()?.text=="cid-44" }
        main {
            assertSame(samePlayer,model.player); assertTrue(model.danmaku)
            assertTrue("A manually selected part did not request playback",model.player.playWhenReady)
        }
        assertEquals(2,f.danmakuReads.get())
        main { model.danmaku(false) }
        f.danmakuGate=CountDownLatch(1)
        main { model.danmaku(true) }
        await("The delayed comment request did not begin") { f.danmakuReads.get()==3 }
        main { model.danmaku(false) }
        f.danmakuGate!!.countDown(); Thread.sleep(150)
        main { assertTrue(model.danmakuItems.isEmpty()); assertNull(model.danmakuError); f.owner.releasePlayback(model) }
        f.danmakuGate=null
        main { model=f.owner.playback(Route.Watch("BV1NGZtBwELa")) }
        await("The reopened video did not prepare") { model.playback!=null && !model.preparing }
        main {
            assertFalse(model.danmaku); assertEquals(24,model.danmakuFont)
            assertEquals(.5f,model.danmakuArea); assertEquals(.75f,model.danmakuOpacity)
        }
        assertEquals("Disabled comments were fetched in the next video",3,f.danmakuReads.get())
        main { model.danmaku(true) }
        await("Comments did not reenable") { model.danmakuItems.isNotEmpty() }
        main { f.owner.releasePlayback(model); model=f.owner.playback(Route.Watch("BV12qnt6VEM1")) }
        await("Enabled comments were not restored in a new player") { model.danmakuItems.isNotEmpty() }
        main { assertTrue(model.danmaku); assertTrue(PlaybackSettings(f.app).danmaku) }
        assertEquals(5,f.danmakuReads.get())
    }
    @Test fun progressiveMp4StartsWithARangeOnCdnsThatRejectWholeFileRequests() = fixture(durationSeconds=8) { f ->
        f.requireMediaRange=true
        lateinit var model: PlaybackModel
        main { model=f.owner.playback(Route.Watch("BV12qnt6VEM1",progress=2)) }
        await("Expected playback to advance or a terminal error after HTTP 567") {
            model.error!=null || (model.player.isPlaying && model.player.currentPosition>=2100)
        }
        main {
            assertNull(model.error)
            assertEquals(120,model.playback?.quality)
            assertEquals(127,PlaybackSettings(f.app).quality)
        }
        assertEquals(listOf("bytes=0-"),f.firstRequestRanges)
        assertEquals(listOf(127),f.requestedQualities.toList())
    }

    private inner class Fixture(val app: BilightApplication, durationSeconds: Int, audio: Boolean, authenticated: Boolean) {
        @Volatile var requireMediaRange=false
        val firstRequestRanges=CopyOnWriteArrayList<String>()
        private val cachedIds=CopyOnWriteArrayList<String>()
        var languages=listOf("en","zh-CN")
        val subtitleReads=AtomicInteger()
        @Volatile var subtitleGate: CountDownLatch?=null
        val requestedQualities=CopyOnWriteArrayList<Int>()
        val danmakuReads=AtomicInteger()
        @Volatile var danmakuGate: CountDownLatch?=null
        @Volatile var engagementGate: CountDownLatch?=null
        @Volatile var failEngagement=false
        @Volatile var liked=false
        val likePosts=AtomicInteger()
        @Volatile var seedVideoComment=false
        @Volatile var rejectCommentWrites=false
        @Volatile var unconfirmedCommentWrite=false
        @Volatile var commentLikeGate: CountDownLatch?=null
        val commentLikeWrites=AtomicInteger()
        val commentPosts=AtomicInteger()
        val commentMentionReads=AtomicInteger()
        val detailReads=AtomicInteger()
        @Volatile var detailGate: CountDownLatch?=null
        private val file=File(app.cacheDir,"preferences-fixture.mp4").also { encodedFixture(it,audio,durationSeconds) }
        private val bytes=file.readBytes()
        private val api=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); val path=request.url.encodedPath
            val text=when (path) {
                "/x/web-interface/nav" -> """{"code":0,"data":{"isLogin":$authenticated,"mid":900000003,"uname":"隔离测试","wbi_img":{"img_url":"https://i0.hdslb.com/${"a".repeat(32)}.png","sub_url":"https://i0.hdslb.com/${"b".repeat(32)}.png"}}}"""
                "/x/web-interface/archive/relation" -> { check(engagementGate?.await(5,TimeUnit.SECONDS)!=false); if (failEngagement) throw java.io.IOException("Isolated engagement failure"); """{"code":0,"data":{"like":$liked,"coin":0,"favorite":false}}""" }
                "/x/frontend/finger/spi" -> """{"code":0,"data":{"b_3":"fixture-only","b_4":"fixture-only"}}"""
                "/x/web-interface/archive/like" -> { check(request.method=="POST"); likePosts.incrementAndGet(); liked=true; """{"code":0,"data":{}}""" }
                "/x/relation" -> """{"code":0,"data":{"attribute":0}}"""
                "/x/v2/history/report" -> """{"code":0,"data":{}}"""
                "/x/web-interface/wbi/view" -> { detailReads.incrementAndGet(); check(detailGate?.await(15,TimeUnit.SECONDS)!=false); """{"code":0,"data":{"bvid":"${request.url.queryParameter("bvid")}","aid":42,"title":"偏好恢复测试","duration":1,"owner":{"mid":42,"name":"隔离测试"},"pages":[{"cid":43,"page":1,"part":"第一段","duration":1},{"cid":44,"page":2,"part":"第二段","duration":1}],"stat":{}}}""" }
                "/x/player/wbi/playurl" -> {
                    val preferred=request.url.queryParameter("qn")!!.toInt(); requestedQualities+=preferred
                    val quality=minOf(preferred,if(request.url.queryParameter("bvid")=="BV12qnt6VEM1") 120 else 80)
                    """{"code":0,"data":{"quality":$quality,"timelength":1000,"durl":[{"url":"https://audit.bilivideo.com/preferences.mp4"}]}}"""
                }
                "/x/player/wbi/v2" -> {
                    subtitleReads.incrementAndGet(); check(subtitleGate?.await(5,TimeUnit.SECONDS)!=false)
                    val base=request.url.queryParameter("cid")!!.toLong()*100
                    val tracks=languages.mapIndexed { index,language -> """{"id":${base+index},"lan":"$language","lan_doc":"$language","subtitle_url":"https://i0.hdslb.com/${if (language=="en") "en" else "zh"}.json"}""" }.joinToString(",")
                    """{"code":0,"data":{"subtitle":{"subtitles":[$tracks]}}}"""
                }
                "/en.json", "/zh.json" -> """{"body":[{"from":0,"to":1,"content":"字幕测试"}]}"""
                "/x/v2/reply/wbi/main" -> when {
                    seedVideoComment -> """{"code":0,"data":{"cursor":{"is_end":true,"all_count":1},"replies":[{"rpid_str":"2","member":{"mid":42,"uname":"隔离评论"},"content":{"message":"播放页评论"},"like":4,"action":0}]}}"""
                    cachedIds.isEmpty() -> """{"code":0,"data":{"cursor":{"is_end":true,"all_count":0},"replies":[]}}"""
                    else -> """{"code":0,"data":{"cursor":{"is_end":true,"all_count":1},"replies":[{"rpid_str":"1","member":{"mid":42,"uname":"隔离评论"},"content":{"message":"缓存页评论测试"},"like":0}]}}"""
                }
                "/x/v2/reply/detail" -> {
                    check(commentLikeGate?.await(5,TimeUnit.SECONDS)!=false)
                    """{"code":0,"data":{"root":{"rpid_str":"2","type":1,"root":0,"parent":0,"oid":42,"like":4,"action":0}}}"""
                }
                "/x/v2/reply/at" -> {
                    val expected = if (commentMentionReads.get()==0) "" else "隔离"
                    check(request.url.queryParameter("keyword")==expected)
                    commentMentionReads.incrementAndGet()
                    val people=(1..5).joinToString(",") { """{"mid":$it,"name":"隔离候选$it"}""" }
                    """{"code":0,"data":{"groups":[{"items":[$people]}]}}"""
                }
                "/x/v2/reply/action" -> {
                    check(request.method=="POST"); commentLikeWrites.incrementAndGet()
                    check(rejectCommentWrites)
                    """{"code":-403,"message":"隔离点赞被拒绝"}"""
                }
                "/x/v2/reply/add" -> {
                    check(request.method=="POST"); commentPosts.incrementAndGet()
                    if (rejectCommentWrites) """{"code":-403,"message":"隔离评论被拒绝"}"""
                    else if (unconfirmedCommentWrite) """{"code":0,"data":{}}"""
                    else {
                        val form=request.body as FormBody
                        val message=(0 until form.size).first { form.name(it)=="message" }.let(form::value)
                        """{"code":0,"data":{"reply":{"rpid_str":"17","type":1,"root":0,"parent":0,"oid":42,"mid":900000003,"member":{"mid":900000003,"uname":"隔离测试"},"content":{"message":${JSONObject.quote(message)}}}}}"""
                    }
                }
                "/x/v1/dm/list.so" -> {
                    danmakuReads.incrementAndGet(); check(danmakuGate?.await(5,TimeUnit.SECONDS)!=false)
                    """<i><d p="0,1,25,16777215">cid-${request.url.queryParameter("oid")}</d></i>"""
                }
                else -> error("Unexpected fixture request: $path")
            }
            val body=if(path=="/x/v1/dm/list.so") ByteArrayOutputStream().also { output ->
                val deflater=Deflater(6,true)
                try { DeflaterOutputStream(output,deflater).use { it.write(text.toByteArray()) } } finally { deflater.end() }
            }.toByteArray() else text.toByteArray()
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body.toResponseBody("application/octet-stream".toMediaType())).build()
        }.build()
        private val media=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request()
            val response=Response.Builder().request(request).protocol(Protocol.HTTP_1_1).message("Fixture")
            if (requireMediaRange) {
                val headers=request.headers("Range")
                if (firstRequestRanges.isEmpty() && headers.isNotEmpty()) firstRequestRanges.addAll(headers)
                val start=headers.singleOrNull()?.let { Regex("bytes=(\\d+)-").matchEntire(it)?.groupValues?.get(1)?.toInt() }
                if (start==null || start !in bytes.indices) {
                    response.code(567).body(ByteArray(0).toResponseBody()).build()
                } else {
                    response.code(206).header("Content-Range","bytes $start-${bytes.lastIndex}/${bytes.size}")
                        .body(bytes.copyOfRange(start,bytes.size).toResponseBody("video/mp4".toMediaType())).build()
                }
            } else response.code(200).body(bytes.toResponseBody("video/mp4".toMediaType())).build()
        }.build()
        private val store=ViewModelStore()
        val owner: AppModel
        fun cachedVideo(): Route.Watch {
            await("The fixture download account did not restore") { owner.downloads.ready && owner.user!=null }
            val detail=kotlinx.coroutines.runBlocking { owner.repository.detail("BV12qnt6VEM1") }
            val id=java.util.UUID.randomUUID().toString()
            val destination=File(app.filesDir,"downloads/${owner.user!!.mid}/$id/video.mp4")
            destination.parentFile!!.mkdirs(); destination.writeBytes(bytes)
            val record=DownloadRecord(id,detail.video,detail.parts.first(),80,"1080P",DownloadState.COMPLETED)
            main { cachedIds+=id; owner.downloads.items.add(record) }
            return Route.Watch(detail.video.bvid,downloadId=id)
        }
        init {
            val http=BiliHttp(object: SecureStore { var saved: ByteArray?=null; override fun load()=saved; override fun save(bytes: ByteArray) { saved=bytes }; override fun clear() { saved=null } },api)
            if (authenticated) kotlinx.coroutines.runBlocking { http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only") }
            lateinit var value: AppModel
            main { value=ViewModelProvider(store,object: ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST") override fun <T: androidx.lifecycle.ViewModel> create(modelClass: Class<T>)=AppModel(app,http) { a,r -> PlaybackModel(a,r,media) } as T
            })[AppModel::class.java] }
            owner=value
            await("The isolated session did not restore") { !owner.restoring }
        }
        fun close() {
            main { cachedIds.forEach(owner.downloads::remove) }
            subtitleGate?.countDown(); danmakuGate?.countDown(); engagementGate?.countDown(); detailGate?.countDown(); commentLikeGate?.countDown()
            main { store.clear() }; api.dispatcher.cancelAll(); media.dispatcher.cancelAll(); file.delete()
        }
    }
}

@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package app.bilight.android

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Timeline
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.*
import app.bilight.android.playback.parsedDashManifest
import org.junit.Assert.*
import org.junit.Test

class PlaybackPipelineTest {
    @Test fun staticDashIsSideloadedWithoutOpaqueUriManifestRequests() {
        val track = Track(80,"https://fixture.bilivideo.com/video","avc1.640028",1000000,1920,1080,"0-999","1000-1999")
        val playback = Playback(80,listOf(Quality(80,"1080P")),120.0,track,null,null)
        val manifest = parsedDashManifest(playback)
        assertEquals(120000L, manifest.durationMs)
        assertEquals(1, manifest.periodCount)
        var windows = 0
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val item = MediaItem.Builder().setUri("https://www.bilibili.com/bilight-manifest.mpd")
                .setMediaMetadata(MediaMetadata.Builder().setTitle("锁屏DASH测试").build()).build()
            val source = DashMediaSource.Factory(DefaultDataSource.Factory(ApplicationProvider.getApplicationContext()))
                .createMediaSource(manifest,item)
            val caller = MediaSource.MediaSourceCaller { _, timeline -> windows = timeline.windowCount }
            source.prepareSource(caller, null, PlayerId.UNSET)
            // A sideloaded static manifest publishes its timeline immediately, without a data: URI loader.
            assertEquals(1, windows)
            assertEquals("锁屏DASH测试",source.mediaItem.mediaMetadata.title)
            source.releaseSource(caller)
        }
    }
    @Test fun opaqueDataUrisWouldTriggerTheOriginalFrameworkFailure() {
        try { Uri.parse("data:application/dash+xml;base64,PHg+").getQueryParameter("CMCD"); fail() }
        catch (_: UnsupportedOperationException) { }
    }
}

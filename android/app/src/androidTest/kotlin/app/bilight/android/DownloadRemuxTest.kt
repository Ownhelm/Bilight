package app.bilight.android

import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.test.core.app.ApplicationProvider
import app.bilight.android.downloads.muxTracks
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class DownloadRemuxTest {
    @Test fun realAvcAndAacTracksProduceASeekableMp4WithBothTracks() = runBlocking(Dispatchers.IO) {
        val context=ApplicationProvider.getApplicationContext<android.content.Context>()
        val folder=File(context.cacheDir,"remux-test-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val video=File(folder,"video.mp4"); val audio=File(folder,"audio.mp4"); val output=File(folder,"output.mp4")
            encodedFixture(video,false); encodedFixture(audio,true); muxTracks(video,audio,output)
            val extractor=MediaExtractor()
            try {
                extractor.setDataSource(output.absolutePath)
                assertEquals(2,extractor.trackCount)
                val formats=(0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                assertEquals(setOf("video/avc","audio/mp4a-latm"),formats.map { it.getString(MediaFormat.KEY_MIME) }.toSet())
                assertTrue(formats.all { it.getLong(MediaFormat.KEY_DURATION)>800000 })
                extractor.selectTrack(formats.indexOfFirst { it.getString(MediaFormat.KEY_MIME)=="video/avc" })
                extractor.seekTo(500000,MediaExtractor.SEEK_TO_PREVIOUS_SYNC); assertTrue(extractor.sampleTime>=0)
            } finally { extractor.release() }
            assertFalse(File(folder,"merged.tmp.mp4").exists())
        } finally { folder.deleteRecursively() }
    }
}

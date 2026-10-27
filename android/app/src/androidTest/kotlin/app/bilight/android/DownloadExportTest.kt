package app.bilight.android

import android.content.Context
import androidx.core.content.FileProvider
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class DownloadExportTest {
    @Test fun exportedMp4UsesAReadableContentUriWithoutExposingPrivatePaths() = runBlocking(Dispatchers.IO) {
        val context=ApplicationProvider.getApplicationContext<Context>()
        val folder=File(context.filesDir,"downloads/export-test-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val output=File(folder,"video.mp4"); encodedFixture(output,false)
            val uri=FileProvider.getUriForFile(context,"${context.packageName}.files",output)
            assertEquals("content",uri.scheme); assertEquals("video/mp4",context.contentResolver.getType(uri))
            assertFalse(uri.toString().contains(context.filesDir.absolutePath))
            context.contentResolver.openInputStream(uri)!!.use { assertTrue(it.readBytes().isNotEmpty()) }
        } finally { folder.deleteRecursively() }
    }
}

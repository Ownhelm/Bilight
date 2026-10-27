package app.bilight.android.downloads

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import app.bilight.android.core.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.*
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal suspend fun Call.awaitResponse(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object: Callback {
        override fun onFailure(call: Call, e: IOException) { if (continuation.isActive) continuation.resumeWithException(IOException("下载连接中断，请重试。")) }
        override fun onResponse(call: Call, response: Response) {
            if (continuation.isActive) continuation.resume(response, onCancellation = { _, value, _ -> value.close() }) else response.close()
        }
    })
}

/** Stream bounded chunks to disk; never hold a whole 4K track in memory. */
@OptIn(kotlinx.coroutines.InternalCoroutinesApi::class)
internal suspend fun downloadTrack(client: OkHttpClient, url: String, destination: File, progress: suspend (Long, Long) -> Unit) {
    if (mediaUrl(url) != url) invalid("下载地址不受信任。")
    val metadata = File(destination.parentFile, destination.name + ".range")
    val previous = if (metadata.exists()) runCatching {
        val lines = metadata.readLines(); ByteResume(lines[0], lines[1].toLong())
    }.getOrNull() else null
    var offset = destination.takeIf { it.exists() }?.length() ?: 0L
    // Without a strong validator, a fresh signed URL cannot safely reuse a partial prefix.
    if (previous == null || previous.etag.isEmpty() || offset > previous.total) {
        destination.delete(); metadata.delete(); offset = 0
    }
    if (offset > 0 && offset == previous?.total) { progress(offset, offset); return }
    val request = Request.Builder().url(url).header("Referer", "https://www.bilibili.com/")
        .header("User-Agent", BiliHttp.USER_AGENT).header("Accept-Encoding", "identity")
    if (offset > 0) request.header("Range", "bytes=$offset-").header("If-Range", previous!!.etag)
    val call = client.newCall(request.build())
    // Also cancel an in-progress blocking body read, not only response-header waiting.
    val cancellation = currentCoroutineContext()[kotlinx.coroutines.Job]!!.invokeOnCompletion(onCancelling = true, invokeImmediately = true) { if (it != null) call.cancel() }
    try {
        call.awaitResponse().use { response ->
            val type = response.header("Content-Type").orEmpty().substringBefore(';').lowercase()
            if (!(type.startsWith("video/") || type.startsWith("audio/") || type == "application/octet-stream")) invalid("下载响应不是视频或音频。")
            val body = response.body ?: invalid()
            val proof = ByteResume.validate(response.code, offset, body.contentLength(), response.header("Content-Range"), response.header("ETag"), previous)
            metadata.writeText("${proof.etag}\n${proof.total}")
            var received = offset
            var lastUpdate = 0L
            body.byteStream().use { input -> java.io.FileOutputStream(destination, offset > 0).use { output ->
                val chunk = ByteArray(65536)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(chunk); if (count < 0) break
                    received += count
                    if (received > proof.total) invalid("下载响应超过声明长度。")
                    output.write(chunk, 0, count)
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (now - lastUpdate >= 250) { progress(received, proof.total); lastUpdate = now }
                }
                output.fd.sync()
            } }
            if (received != proof.total) throw IOException("下载连接提前结束，请继续下载。")
            progress(received, proof.total)
        }
    } catch (e: IOException) {
        currentCoroutineContext().ensureActive()
        throw e
    } finally { cancellation.dispose() }
}

/** Remux separate AVC/AAC tracks. The output becomes visible only after a successful atomic rename. */
internal suspend fun muxTracks(video: File, audio: File?, output: File) {
    val temporary = File(output.parentFile, "merged.tmp.mp4").apply { delete() }
    val extractors = mutableListOf<MediaExtractor>()
    var muxer: MediaMuxer? = null
    var started = false
    try {
        val target = MediaMuxer(temporary.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4).also { muxer = it }
        data class Input(val extractor: MediaExtractor, val input: Int, val output: Int, val capacity: Int)
        val tracks = mutableListOf<Input>()
        for ((file, prefix) in listOfNotNull(video to "video/", audio?.let { it to "audio/" })) {
            val extractor = MediaExtractor().also { extractors += it; it.setDataSource(file.absolutePath) }
            val index = (0 until extractor.trackCount).firstOrNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith(prefix) == true } ?: invalid("下载文件缺少${if (prefix == "video/") "视频" else "音频"}轨道。")
            val format = extractor.getTrackFormat(index)
            val capacity = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 4 * 1024 * 1024
            if (capacity !in 1..16 * 1024 * 1024) invalid("媒体帧大小超出处理范围。")
            extractor.selectTrack(index)
            tracks += Input(extractor, index, target.addTrack(format), capacity)
            if (audio == null) {
                val audioIndex = (0 until extractor.trackCount).firstOrNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
                if (audioIndex != null) {
                    val ownAudio = MediaExtractor().also { extractors += it; it.setDataSource(file.absolutePath); it.selectTrack(audioIndex) }
                    val audioFormat = ownAudio.getTrackFormat(audioIndex)
                    tracks += Input(ownAudio, audioIndex, target.addTrack(audioFormat), 1024 * 1024)
                }
            }
        }
        target.start(); started = true
        val buffer = ByteBuffer.allocateDirect(tracks.maxOf { it.capacity }.coerceAtLeast(1024 * 1024))
        val info = MediaCodec.BufferInfo()
        // Feed tracks in timestamp order so long videos remain seekable after remuxing.
        while (true) {
            currentCoroutineContext().ensureActive()
            val track = tracks.filter { it.extractor.sampleTime >= 0 }.minByOrNull { it.extractor.sampleTime } ?: break
            buffer.clear(); val size = track.extractor.readSampleData(buffer, 0)
            if (size < 0) break
            if (size > buffer.capacity()) invalid("媒体帧大小超出缓冲范围。")
            info.set(0, size, track.extractor.sampleTime, if (track.extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            target.writeSampleData(track.output, buffer, info); track.extractor.advance()
        }
        target.stop(); started = false; target.release(); muxer = null
        if (temporary.length() <= 0 || !temporary.renameTo(output)) invalid("无法保存下载文件，请检查可用空间。")
    } finally {
        extractors.forEach { it.release() }
        if (started) runCatching { muxer?.stop() }; runCatching { muxer?.release() }
        temporary.delete()
    }
}

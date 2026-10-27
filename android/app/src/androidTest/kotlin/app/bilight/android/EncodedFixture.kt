package app.bilight.android

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/** Generate tiny synthetic media on the test device. No promotional or account-related media is stored in Git. */
internal fun encodedFixture(file: File, audio: Boolean) {
    val mime=if (audio) "audio/mp4a-latm" else "video/avc"
    val format=if (audio) MediaFormat.createAudioFormat(mime,44100,1).apply {
        setInteger(MediaFormat.KEY_AAC_PROFILE,MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        setInteger(MediaFormat.KEY_BIT_RATE,64000)
    } else MediaFormat.createVideoFormat(mime,64,64).apply {
        setInteger(MediaFormat.KEY_COLOR_FORMAT,MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        setInteger(MediaFormat.KEY_BIT_RATE,100000); setInteger(MediaFormat.KEY_FRAME_RATE,10); setInteger(MediaFormat.KEY_I_FRAME_INTERVAL,1)
    }
    val codec=MediaCodec.createEncoderByType(mime)
    val muxer=MediaMuxer(file.absolutePath,MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    var track=-1; var started=false; var input=0; var samples=0L; var ended=false; var done=false
    try {
        codec.configure(format,null,null,MediaCodec.CONFIGURE_FLAG_ENCODE); codec.start()
        val info=MediaCodec.BufferInfo(); val deadline=System.nanoTime()+15_000_000_000L
        while (!done && System.nanoTime()<deadline) {
            if (!ended) {
                val index=codec.dequeueInputBuffer(10000)
                if (index>=0) {
                    val buffer=codec.getInputBuffer(index)!!; buffer.clear()
                    if (input>=if (audio) 44 else 10) { codec.queueInputBuffer(index,0,0,if (audio) samples*1_000_000/44100 else 1_000_000,MediaCodec.BUFFER_FLAG_END_OF_STREAM); ended=true }
                    else {
                        val bytes=if (audio) ByteArray(minOf(2048,buffer.remaining())/2*2) { i -> if (i%2==0) ((i/2+samples)%200).toByte() else 0 } else ByteArray(64*64*3/2) { i -> if (i<64*64) (32+input*16).toByte() else 128.toByte() }
                        val pts=if (audio) samples*1_000_000/44100 else input*100000L
                        buffer.put(bytes); codec.queueInputBuffer(index,0,bytes.size,pts,0); input++; if (audio) samples+=bytes.size/2
                    }
                }
            }
            when (val index=codec.dequeueOutputBuffer(info,10000)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { track=muxer.addTrack(codec.outputFormat); muxer.start(); started=true }
                else -> if (index>=0) {
                    if (info.size>0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG==0) { check(started); muxer.writeSampleData(track,codec.getOutputBuffer(index)!!,info) }
                    done=info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM!=0; codec.releaseOutputBuffer(index,false)
                }
            }
        }
        check(done && started) { "Fixture encoding did not finish" }
    } finally { runCatching { codec.stop() }; codec.release(); if (started) muxer.stop(); muxer.release() }
}

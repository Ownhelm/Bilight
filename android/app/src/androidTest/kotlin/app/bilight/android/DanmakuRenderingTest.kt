package app.bilight.android

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.media3.common.Player
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.playback.Danmaku
import app.bilight.android.playback.DanmakuView
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class DanmakuRenderingTest {
    @get:Rule val activity=ActivityScenarioRule(MainActivity::class.java)
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    @Test fun fullscreenTextStartsBelowBothSystemInsetsAndControls() {
        val player=Proxy.newProxyInstance(Player::class.java.classLoader,arrayOf(Player::class.java)) { _,method,_ ->
            when (method.name) { "getCurrentPosition" -> 2000L; "isPlaying" -> false; else -> throw UnsupportedOperationException(method.name) }
        } as Player
        lateinit var screen: ComponentActivity
        lateinit var view: DanmakuView
        activity.scenario.onActivity {
            screen=it; androidx.core.view.WindowCompat.setDecorFitsSystemWindows(it.window,false)
            view=DanmakuView(it).apply { setBackgroundColor(Color.BLACK) }
            it.setContentView(FrameLayout(it).apply { addView(view,FrameLayout.LayoutParams(-1,-1)) })
            view.update(player,listOf(Danmaku(1,0.0,"弹幕安全区域",1)),true,20,1f,1f,true)
        }
        val ready=CountDownLatch(1); var bitmap: Bitmap?=null; var status=-1; var reservedTop=0
        instrumentation.runOnMainSync {
            view.postDelayed({
                val location=IntArray(2); view.getLocationInWindow(location)
                val insets=androidx.core.view.ViewCompat.getRootWindowInsets(view)!!.getInsetsIgnoringVisibility(androidx.core.view.WindowInsetsCompat.Type.systemBars() or androidx.core.view.WindowInsetsCompat.Type.displayCutout())
                val safeTop=(insets.top-location[1]).coerceAtLeast(0)
                assertTrue("The regression requires an edge-to-edge player",safeTop>0)
                reservedTop=safeTop+(48*view.resources.displayMetrics.density).toInt()
                val output=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                PixelCopy.request(screen.window,Rect(location[0],location[1],location[0]+view.width,location[1]+view.height),output,{ result -> status=result; bitmap=output; ready.countDown() },Handler(Looper.getMainLooper()))
            },200)
        }
        assertTrue("PixelCopy did not finish",ready.await(5,TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS,status)
        val output=bitmap!!
        try {
            val pixels=IntArray(output.width*output.height); output.getPixels(pixels,0,output.width,0,0,output.width,output.height)
            val white=pixels.indices.filter { pixels[it]==Color.WHITE }
            assertTrue("Filled glyphs were not rendered",white.size>50)
            assertTrue("Danmaku overlapped the top controls",white.minOf { it/output.width }>=reservedTop)
        } finally { output.recycle() }
    }
    @Test fun hardwareRenderedGlyphsKeepWhiteInkAndMoveEveryFrame() {
        var position=2000L
        val player=Proxy.newProxyInstance(Player::class.java.classLoader,arrayOf(Player::class.java)) { _,method,_ ->
            when (method.name) { "getCurrentPosition" -> position; "isPlaying" -> false; else -> throw UnsupportedOperationException(method.name) }
        } as Player
        lateinit var screen: ComponentActivity
        lateinit var view: DanmakuView
        activity.scenario.onActivity {
            screen=it
            view=DanmakuView(it)
            it.setContentView(FrameLayout(it).apply { addView(view,FrameLayout.LayoutParams(-1,-1)) })
            view.update(player,listOf(Danmaku(1,0.0,"弹幕清晰",1)),true,20,1f,1f)
        }
        fun capture(background: Int,time: Long): Bitmap {
            val ready=CountDownLatch(1); var bitmap: Bitmap?=null; var status=-1
            instrumentation.runOnMainSync {
                position=time; view.setBackgroundColor(background); view.invalidate()
                view.postDelayed({
                    val coordinates=IntArray(2); view.getLocationInWindow(coordinates)
                    val bounds=Rect(coordinates[0],coordinates[1],coordinates[0]+view.width,coordinates[1]+view.height)
                    val output=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                    PixelCopy.request(screen.window,bounds,output,{ result -> status=result; bitmap=output; ready.countDown() },Handler(Looper.getMainLooper()))
                },100)
            }
            assertTrue("PixelCopy did not finish",ready.await(5,TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS,status)
            return bitmap!!
        }
        fun whitePixels(bitmap: Bitmap): Set<Int> {
            val pixels=IntArray(bitmap.width*bitmap.height)
            bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
            return pixels.indices.filter { pixels[it]==Color.WHITE }.toSet()
        }
        val first=capture(Color.rgb(12,36,60),2000)
        val second=capture(Color.rgb(40,100,20),2000)
        val moved=capture(Color.rgb(40,100,20),2016)
        try {
            val a=whitePixels(first); val b=whitePixels(second); val c=whitePixels(moved)
            assertTrue("Filled glyphs were not rendered",a.size>50)
            assertEquals("Video background changed the text ink",a,b)
            val left=a.minOf { it%first.width }; val next=c.minOf { it%moved.width }
            assertTrue("Danmaku did not advance smoothly at a 16ms frame step",left-next in 1..8)
        } finally { first.recycle(); second.recycle(); moved.recycle() }
    }
}

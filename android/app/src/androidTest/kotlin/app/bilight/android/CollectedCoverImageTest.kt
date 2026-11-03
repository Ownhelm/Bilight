package app.bilight.android

import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import app.bilight.android.core.BiliHttp
import app.bilight.android.ui.ImageLoadState
import app.bilight.android.ui.RemoteImage
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicReference

/** Real Coil/Compose rendering with an isolated PNG response; no account or external network. */
class CollectedCoverImageTest {
    @get:Rule val rule=createAndroidComposeRule<ComponentActivity>()
    @Test fun collectedBiliimgCoverLoadsAndRendersPixels() {
        check(Build.HARDWARE in listOf("ranchu","goldfish"))
        val context=rule.activity.applicationContext
        val original=SingletonImageLoader.get(context)
        val state=AtomicReference(ImageLoadState.LOADING)
        val requested=AtomicReference<Request>()
        val bitmap=Bitmap.createBitmap(32,32,Bitmap.Config.ARGB_8888)
        for (y in 0 until 32) for (x in 0 until 32) bitmap.setPixel(x,y,Color.rgb(x*8,y*8,120))
        val bytes=ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) }.toByteArray()
        bitmap.recycle()
        val client=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); check(request.url.host=="archive.biliimg.com"); requested.set(request)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(bytes.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val loader=ImageLoader.Builder(context).components { add(OkHttpNetworkFetcherFactory(callFactory={ client })) }.build()
        SingletonImageLoader.setUnsafe(loader)
        try {
            rule.setContent {
                RemoteImage("https://archive.biliimg.com/bfs/archive/isolated-cover.png","隔离收藏封面",Modifier.size(112.dp,72.dp).testTag("cover"),onLoadState={ state.set(it) })
            }
            rule.waitUntil(5000) { state.get()!=ImageLoadState.LOADING }
            assertEquals(ImageLoadState.READY,state.get())
            assertEquals("https://www.bilibili.com/",requested.get().header("Referer"))
            assertEquals(BiliHttp.USER_AGENT,requested.get().header("User-Agent")); assertNull(requested.get().header("Cookie"))
            val pixels=rule.onNodeWithTag("cover").captureToImage().toPixelMap()
            val colors=mutableSetOf<androidx.compose.ui.graphics.Color>()
            for (y in 0 until pixels.height step 4) for (x in 0 until pixels.width step 4) colors+=pixels[x,y]
            assertTrue("The cover rendered a blank placeholder",colors.size>20)
        } finally { SingletonImageLoader.setUnsafe(original); loader.shutdown(); client.dispatcher.cancelAll() }
    }
}

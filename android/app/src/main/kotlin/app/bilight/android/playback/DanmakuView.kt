package app.bilight.android.playback

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.Choreographer
import android.view.View
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.media3.common.Player
import app.bilight.android.core.clean
import app.bilight.android.core.invalid
import app.bilight.android.core.BiliFailure
import org.w3c.dom.Element
import org.json.JSONObject
import org.xml.sax.InputSource
import org.xml.sax.SAXParseException
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.StringReader
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.util.zip.GZIPInputStream
import java.util.zip.Inflater
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.math.max
import kotlin.math.min

data class Danmaku(val id: Int,val time: Double,val text: String,val mode: Int) {
    companion object {
    private const val MAX_BYTES=8_000_000
    private fun malformed(): Nothing = throw BiliFailure("DANMAKU_FORMAT","弹幕数据暂时无法解析，请稍后重试。")
    private fun bounded(input: InputStream): ByteArray {
        val output=ByteArrayOutputStream(); val buffer=ByteArray(8192)
        while (true) {
            val count=input.read(buffer); if (count<0) break
            if (output.size()+count>MAX_BYTES) invalid("弹幕文件过大。")
            output.write(buffer,0,count)
        }
        return output.toByteArray()
    }
    private fun decode(bytes: ByteArray): ByteArray {
        if (bytes.size>MAX_BYTES) invalid("弹幕文件过大。")
        if (bytes.isEmpty()) malformed()
        var start=if (bytes.size>=3 && bytes[0]==0xef.toByte() && bytes[1]==0xbb.toByte() && bytes[2]==0xbf.toByte()) 3 else 0
        while (start<bytes.size && when(bytes[start].toInt()) { 9,10,13,32 -> true; else -> false }) start++
        val first=bytes.getOrNull(start)?.toInt()
        if (first==60 || first==123) return bytes
        try {
            if (bytes.size>=2 && bytes[0]==0x1f.toByte() && bytes[1]==0x8b.toByte()) return GZIPInputStream(ByteArrayInputStream(bytes)).use(::bounded)
            val zlib=bytes.size>=2 && (bytes[0].toInt() and 15)==8 && (((bytes[0].toInt() and 255)*256+(bytes[1].toInt() and 255))%31==0)
            // B站 list.so normally returns raw DEFLATE, which OkHttp does not automatically decode.
            val inflater=Inflater(!zlib)
            try {
                inflater.setInput(bytes); val output=ByteArrayOutputStream(); val buffer=ByteArray(8192)
                while (!inflater.finished()) {
                    val count=inflater.inflate(buffer)
                    if (count==0 && !inflater.finished()) malformed()
                    if (output.size()+count>MAX_BYTES) invalid("弹幕文件过大。")
                    output.write(buffer,0,count)
                }
                if (inflater.remaining!=0) malformed()
                return output.toByteArray()
            } finally { inflater.end() }
        } catch (e: BiliFailure) { throw e } catch (_: Exception) { malformed() }
    }
    fun parse(bytes: ByteArray): List<Danmaku> {
        val content=decode(bytes)
        val xml=try { Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(content)).toString().removePrefix("\uFEFF") }
            catch (_: CharacterCodingException) { malformed() }
        if (xml.contains("<!DOCTYPE",true) || xml.contains("<!ENTITY",true)) invalid("弹幕格式不安全。")
        if (xml.trimStart().startsWith('{')) {
            val response=try { JSONObject(xml) } catch (_: Exception) { malformed() }
            val code=response.optInt("code")
            if (code!=0) throw BiliFailure("$code","${clean(response.optString("message",response.optString("msg","B站暂时无法提供弹幕")),200)}（$code）")
            malformed()
        }
        val factory=DocumentBuilderFactory.newInstance().apply { isExpandEntityReferences=false; isNamespaceAware=false }
        val document=try {
            factory.newDocumentBuilder().apply {
                setEntityResolver { _,_ -> throw org.xml.sax.SAXException("External XML resources are disabled") }
                setErrorHandler(object: DefaultHandler() {
                    override fun error(e: SAXParseException) { throw e }
                    override fun fatalError(e: SAXParseException) { throw e }
                })
            }.parse(InputSource(StringReader(xml)))
        } catch (_: Exception) { malformed() }
        if (document.documentElement.tagName!="i") invalid("弹幕暂时无法读取。")
        val rows=document.getElementsByTagName("d")
        return (0 until min(10000,rows.length)).mapNotNull { i ->
            val node=rows.item(i) as? Element ?: return@mapNotNull null; val p=node.getAttribute("p").split(',')
            val time=p.getOrNull(0)?.toDoubleOrNull() ?: return@mapNotNull null; val mode=p.getOrNull(1)?.toIntOrNull() ?: return@mapNotNull null
            val text=clean(node.textContent,300)
            if (!time.isFinite() || time<0 || time>=86400 || mode !in listOf(1,4,5,6) || text.isBlank()) null else Danmaku(i,time,text,mode)
        }.sortedWith(compareBy<Danmaku> { it.time }.thenBy { it.id })
    } }
}
/** Native frame callbacks draw fixed-color text; Compose recomposition is never the animation clock. */
class DanmakuView(context: Context): View(context),Choreographer.FrameCallback {
    private val paint=Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply { color=Color.WHITE; style=Paint.Style.FILL; typeface=android.graphics.Typeface.create("sans-serif-medium",android.graphics.Typeface.NORMAL) }
    private var player: Player?=null
    private var items=emptyList<Danmaku>()
    private var font=20
    private var area=1f
    private var opacity=1f
    private var enabled=false
    private var controlsVisible=false
    private var scheduled=false
    private var index=0
    private var last=Double.NaN
    private var lastWidth=0
    private var lastHeight=0
    private var lastTextSize=0f
    private val location=IntArray(2)
    private data class Label(val item: Danmaku,val lane: Int,val width: Float,val speed: Float)
    private val labels=mutableListOf<Label>()
    private val widths=object: android.util.LruCache<String,Float>(1000) {}
    init { isClickable=false; importantForAccessibility=IMPORTANT_FOR_ACCESSIBILITY_NO }
    fun update(player: Player,items: List<Danmaku>,enabled: Boolean,font: Int,area: Float,opacity: Float,controlsVisible: Boolean = false) {
        val reset=this.items !== items || this.font!=font || this.area!=area
        this.player=player; this.items=items; this.enabled=enabled; this.font=font; this.area=area.coerceIn(.25f,1f); this.opacity=opacity.coerceIn(.2f,1f); this.controlsVisible=controlsVisible
        if (reset) { last=Double.NaN; labels.clear(); widths.evictAll() }
        visibility=if (enabled) VISIBLE else GONE
        if (enabled) { invalidate(); start() } else stop()
    }
    override fun onAttachedToWindow() { super.onAttachedToWindow(); start() }
    override fun onDetachedFromWindow() { stop(); super.onDetachedFromWindow() }
    private fun start() { if (!scheduled && enabled && isAttachedToWindow && items.isNotEmpty()) { scheduled=true; Choreographer.getInstance().postFrameCallback(this) } }
    private fun stop() { scheduled=false; Choreographer.getInstance().removeFrameCallback(this) }
    override fun doFrame(frameTimeNanos: Long) { scheduled=false; if (!enabled || !isAttachedToWindow) return; invalidate(); if (player?.isPlaying==true) start() }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas); val player=player ?: return; if (!enabled || items.isEmpty()) return
        val time=player.currentPosition/1000.0
        val insets=ViewCompat.getRootWindowInsets(this)?.getInsetsIgnoringVisibility(WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.systemBars())
        getLocationInWindow(location)
        // Controls sit inside the safe area; reserve their height after the system inset.
        val top=max(0,(insets?.top ?: 0)-location[1])+(if(controlsVisible) 48f else 4f)*resources.displayMetrics.density
        val left=max(0,(insets?.left ?: 0)-location[0]).toFloat()
        val right=max(0,location[0]+width-(rootView.width-(insets?.right ?: 0))).toFloat()
        val bottom=max(0,location[1]+height-(rootView.height-(insets?.bottom ?: 0)))+(if(controlsVisible) 56f else 0f)*resources.displayMetrics.density
        val usableWidth=(width-left-right).coerceAtLeast(1f)
        paint.textSize=font*resources.displayMetrics.scaledDensity
        if (lastTextSize!=paint.textSize) { widths.evictAll(); labels.clear(); last=Double.NaN; lastTextSize=paint.textSize }
        paint.alpha=(opacity*255).toInt(); paint.setShadowLayer(1.25f*resources.displayMetrics.density,0f,0f,Color.BLACK)
        val line=paint.textSize*1.5f
        val lanes=(((height-top-bottom)*area)/line).toInt().coerceIn(1,18)
        val reset=!last.isFinite() || time<last-.2 || time-last>1.5 || lastWidth!=width || lastHeight!=height
        if (reset) { labels.clear(); index=items.binarySearchBy((time-8).coerceAtLeast(0.0)) { it.time }.let { if (it<0) -it-1 else it }; lastWidth=width; lastHeight=height }
        labels.removeAll { time-it.item.time>=if (it.item.mode in listOf(4,5)) 4 else 8 }
        while (index<items.size && items[index].time<=time) {
            val item=items[index++]; val fixed=item.mode in listOf(4,5)
            if (time-item.time >= (if (fixed) 4 else 8) || labels.size>=40) continue
            val textWidth=widths.get(item.text) ?: paint.measureText(item.text).also { widths.put(item.text,it) }
            val speed=(usableWidth+textWidth)/8f
            val candidates=if (item.mode==4) (lanes-1 downTo 0) else (0 until lanes)
            val lane=candidates.firstOrNull { lane -> labels.filter { it.lane==lane }.all { previous ->
                val age=item.time-previous.item.time
                if (fixed || previous.item.mode in listOf(4,5)) age>=4
                else {
                    val gap=previous.speed*age-previous.width
                    gap>24*resources.displayMetrics.density && (speed<=previous.speed || gap/(speed-previous.speed)>=8-age)
                }
            } }
            if (lane!=null) labels.add(Label(item,lane,textWidth,speed))
        }
        canvas.save(); canvas.clipRect(left,top,width-right,min(height-bottom,top+lanes*line))
        for (label in labels) {
            val age=(time-label.item.time).toFloat()
            val x=when (label.item.mode) { 4,5 -> left+(usableWidth-label.width)/2; 6 -> left- label.width+label.speed*age; else -> left+usableWidth-label.speed*age }
            canvas.drawText(label.item.text,x,top+(label.lane+1)*line-paint.textSize*.25f,paint)
        }
        canvas.restore(); last=time
    }
}

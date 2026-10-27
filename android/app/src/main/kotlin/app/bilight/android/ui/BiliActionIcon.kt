package app.bilight.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin

enum class BiliActionKind { LIKE, COIN, FAVORITE, DOWNLOAD }

/** Original silhouettes shared with the iOS implementation; visible ink fits the same 22dp bounds. */
@Composable fun BiliActionIcon(kind: BiliActionKind, label: String, selected: Boolean = false) {
    val color = if (selected) Pink else Muted
    Canvas(Modifier.size(22.dp).semantics { contentDescription = label }) {
        val path = Path()
        when (kind) {
            BiliActionKind.LIKE -> {
                path.addRoundRect(RoundRect(Rect(2f,15f,8f,33f),CornerRadius(1.8f)))
                path.moveTo(11f,15f); path.cubicTo(16f,9f,16f,8f,18f,4f)
                path.cubicTo(19f,0f,24f,2f,24f,7f); path.lineTo(23f,14f); path.lineTo(31f,14f)
                path.quadraticTo(35f,14f,34f,19f); path.lineTo(31f,30f)
                path.quadraticTo(30f,33f,27f,33f); path.lineTo(11f,33f); path.close()
            }
            BiliActionKind.COIN -> {
                drawCircle(color)
                val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                    this.color = android.graphics.Color.WHITE; textSize = size.height*15f/22; textAlign = android.graphics.Paint.Align.CENTER
                    typeface = android.graphics.Typeface.create("sans-serif",android.graphics.Typeface.NORMAL)
                }
                drawContext.canvas.nativeCanvas.drawText("币",size.width/2,(size.height-paint.fontMetrics.ascent-paint.fontMetrics.descent)/2,paint)
                return@Canvas
            }
            BiliActionKind.FAVORITE -> {
                val points = (0..9).map { i -> val angle=i*Math.PI/5-Math.PI/2; val r=if (i%2==0) .49f else .255f; Offset(18+cos(angle).toFloat()*r*36,18+sin(angle).toFloat()*r*36) }
                fun mix(a: Offset,b: Offset) = a*.86f+b*.14f
                val start=mix(points[0],points[9]); path.moveTo(start.x,start.y)
                for (i in 0..9) { val next=mix(points[i],points[(i+1)%10]); path.quadraticTo(points[i].x,points[i].y,next.x,next.y); val end=mix(points[(i+1)%10],points[i]); path.lineTo(end.x,end.y) }
                path.close()
            }
            BiliActionKind.DOWNLOAD -> {
                path.addRoundRect(RoundRect(Rect(1f,7f,35f,33f),CornerRadius(5f)))
                path.addRoundRect(RoundRect(Rect(8f,3f,20f,13f),CornerRadius(3f)))
            }
        }
        val bounds=path.getBounds()
        withTransform({ scale(size.width/bounds.width,size.height/bounds.height,Offset.Zero); translate(-bounds.left,-bounds.top) }) { drawPath(path,color) }
        if (kind==BiliActionKind.DOWNLOAD) {
            val arrow=Path().apply { moveTo(size.width*.46f,size.height*.32f); lineTo(size.width*.54f,size.height*.32f); lineTo(size.width*.54f,size.height*.61f); lineTo(size.width*.65f,size.height*.5f); lineTo(size.width*.72f,size.height*.58f); lineTo(size.width*.5f,size.height*.8f); lineTo(size.width*.28f,size.height*.58f); lineTo(size.width*.35f,size.height*.5f); lineTo(size.width*.46f,size.height*.61f); close() }
            drawPath(arrow,Color.White)
        }
    }
}

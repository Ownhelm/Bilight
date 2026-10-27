package app.bilight.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import coil3.network.NetworkHeaders
import coil3.network.httpHeaders
import coil3.request.ImageRequest
import app.bilight.android.core.*

val Pink = Color(0xffd63d6e)
val Blue = Color(0xff1599c5)
val Muted = Color(0xff6f7481)
val Soft = Color(0xfff5f6f8)
enum class ImageLoadState { LOADING, READY, FAILED }
@Composable fun RemoteImage(url: String?, description: String?, modifier: Modifier, crop: ContentScale = ContentScale.Crop, onLoadState: (ImageLoadState) -> Unit = {}, backgroundColor: Color = Soft) {
    val context = LocalContext.current
    val request = remember(url) { ImageRequest.Builder(context).data(url?.let(::secureUrl)).httpHeaders(NetworkHeaders.Builder().set("Referer","https://www.bilibili.com/").set("User-Agent",BiliHttp.USER_AGENT).build()).build() }
    AsyncImage(request,description,modifier.background(backgroundColor),contentScale=crop,onLoading={ onLoadState(ImageLoadState.LOADING) },onSuccess={ onLoadState(ImageLoadState.READY) },onError={ onLoadState(ImageLoadState.FAILED) })
}
@Composable fun Avatar(user: User, size: Int = 36, onClick: (() -> Unit)? = null) {
    RemoteImage(user.avatar,user.name,Modifier.size(size.dp).clip(CircleShape).then(if (onClick != null) Modifier.clickable(onClick=onClick) else Modifier))
}
@Composable fun FollowButton(app: AppModel, mid: Long) {
    if (app.user?.mid == mid) return
    LaunchedEffect(mid,app.user?.mid) { app.readRelation(mid) }
    val r = app.relations[mid]; val busy = app.followBusy[mid] == true
    IconButton(onClick={ app.follow(mid) },enabled=!busy,modifier=Modifier.sizeIn(minWidth=44.dp,minHeight=44.dp)) {
        if (busy) CircularProgressIndicator(Modifier.size(14.dp),strokeWidth=1.5.dp)
        else Surface(shape=RoundedCornerShape(5.dp),border=androidx.compose.foundation.BorderStroke(.75.dp,if (r?.following == true) Pink.copy(alpha=.45f) else Muted.copy(alpha=.4f)),color=Color.Transparent,modifier=Modifier.size(32.dp,26.dp)) {
            Box(contentAlignment=Alignment.Center) { Icon(if (r?.mutual == true) Icons.Rounded.SwapHoriz else if (r?.following == true) Icons.Rounded.Check else Icons.Rounded.Add,if (r?.following == true) "取消关注" else "关注",Modifier.size(14.dp),tint=if (r?.following == true) Pink else Muted) }
        }
    }
}
@Composable fun VideoCard(video: Video, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick=onClick)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f/9).clip(RoundedCornerShape(8.dp))) {
            RemoteImage(video.cover,video.title,Modifier.fillMaxSize())
            Text(clock(video.duration),Modifier.align(Alignment.BottomEnd).padding(5.dp).background(Color.Black.copy(alpha=.6f),RoundedCornerShape(3.dp)).padding(horizontal=4.dp,vertical=1.dp),color=Color.White,fontSize=11.sp)
        }
        Text(video.title,Modifier.padding(top=7.dp),maxLines=2,overflow=TextOverflow.Ellipsis,fontSize=14.sp,lineHeight=20.sp)
        Text(video.owner.name + if (video.views > 0) " · ${count(video.views)}播放" else "",Modifier.padding(top=4.dp),fontSize=11.sp,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis)
    }
}
@Composable fun ErrorNotice(error: String?, retry: (() -> Unit)? = null) {
    if (error == null) return
    Column(Modifier.fillMaxWidth().padding(20.dp),horizontalAlignment=Alignment.CenterHorizontally) {
        Text(error,color=Pink,fontSize=13.sp)
        if (retry != null) TextButton(onClick=retry) { Text("重试") }
    }
}
@Composable fun Loading(label: String = "正在加载") {
    Row(Modifier.fillMaxWidth().padding(24.dp),Arrangement.Center,Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(17.dp),strokeWidth=2.dp); Spacer(Modifier.width(10.dp)); Text(label,color=Muted,fontSize=13.sp) }
}
@Composable fun PageMore(busy: Boolean, more: Boolean, error: String?, load: () -> Unit) {
    ErrorNotice(error,load)
    if (busy) Loading() else if (more && error==null) Box(Modifier.fillMaxWidth(),contentAlignment=Alignment.Center) { TextButton(onClick=load) { Text("加载更多") } }
}
@Composable fun EmptyNotice(label: String) { Text(label,Modifier.fillMaxWidth().padding(24.dp),color=Muted) }
/** Large text gets the full row width instead of being squeezed beside a fixed thumbnail. */
@Composable fun MediaSummaryLayout(thumbnailWidth: Int, thumbnail: @Composable (Modifier) -> Unit, content: @Composable ColumnScope.() -> Unit) {
    if (LocalDensity.current.fontScale>1.4f) Column {
        thumbnail(Modifier.fillMaxWidth().aspectRatio(16f/9))
        Column(Modifier.fillMaxWidth().padding(top=10.dp),content=content)
    } else Row(Modifier.fillMaxWidth()) {
        thumbnail(Modifier.width(thumbnailWidth.dp).aspectRatio(16f/9))
        Column(Modifier.weight(1f).padding(start=12.dp),content=content)
    }
}
@Composable fun SectionTitle(title: String, back: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min=52.dp),verticalAlignment=Alignment.CenterVertically) { IconButton(onClick=back) { Icon(Icons.Rounded.ArrowBack,"返回") }; Text(title,Modifier.weight(1f).padding(end=16.dp),maxLines=2,overflow=TextOverflow.Ellipsis,fontSize=19.sp,fontWeight=FontWeight.SemiBold) }
}

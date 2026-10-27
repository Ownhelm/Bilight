@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package app.bilight.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.bilight.android.R
import app.bilight.android.core.*
import app.bilight.android.core.Collection
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable fun MainApp(app: AppModel) {
    MaterialTheme(colorScheme=lightColorScheme(primary=Pink,secondary=Blue,background=Color.White,surface=Color.White,onSurface=Color(0xff292a32),surfaceContainerLow=Color.White,surfaceContainer=Color.White,surfaceContainerHigh=Color.White,surfaceContainerHighest=Soft,secondaryContainer=Pink.copy(alpha=.1f),onSecondaryContainer=Pink)) {
        Surface(Modifier.fillMaxSize()) {
            val route = app.routes.lastOrNull()
            BackHandler(enabled=route != null) { app.back() }
            when (route) {
                null -> Root(app)
                is Route.Creator -> CreatorScreen(app,route.user)
                is Route.Catalog -> CatalogScreen(app,route)
                is Route.Dynamic -> DynamicScreen(app,route.post)
                is Route.History -> HistoryScreen(app)
                is Route.People -> PeopleScreen(app,route.frequent)
                is Route.Favorites -> FavoritesScreen(app)
                is Route.Favorite -> FolderScreen(app,route.folder)
                is Route.Watch -> VideoScreen(app,route)
                is Route.Downloads -> DownloadsScreen(app)
            }
            if (app.showLogin) LoginDialog(app)
            if (app.showAccount) AccountDialog(app)
            app.error?.let { message -> AlertDialog(onDismissRequest={ app.error=null },text={ Text(message) },confirmButton={ TextButton(onClick={ app.error=null }) { Text("知道了") } }) }
        }
    }
}
@Composable private fun Root(app: AppModel) {
    Scaffold(topBar={ Row(Modifier.statusBarsPadding().fillMaxWidth().height(52.dp).padding(horizontal=12.dp),verticalAlignment=Alignment.CenterVertically) {
        IconButton(onClick={ if (app.requireLogin()) app.showAccount=true }) { app.user?.let { Avatar(it,30) } ?: Icon(Icons.Rounded.AccountCircle,"我的账号",tint=Muted) }
        Spacer(Modifier.weight(1f))
        IconButton(onClick={ app.open(Route.Downloads) }) { Icon(Icons.Rounded.Download,"我的下载",tint=Muted) }
        IconButton(onClick={ if (app.requireLogin()) app.open(Route.History) }) { Icon(Icons.Rounded.History,"我的历史",tint=Muted) }
    } },bottomBar={ NavigationBar(containerColor=Color.White) {
        NavigationBarItem(selected=app.tab==0,onClick={ app.tab=0 },icon={ Icon(Icons.Rounded.Search,"搜索") },label={ Text("搜索") },colors=NavigationBarItemDefaults.colors(selectedIconColor=Pink,selectedTextColor=Pink,indicatorColor=Color.Transparent))
        NavigationBarItem(selected=app.tab==1,onClick={ app.tab=1 },icon={ Icon(painterResource(R.drawable.brand_playback),"关注",Modifier.size(26.dp)) },label={ Text("关注") },colors=NavigationBarItemDefaults.colors(selectedIconColor=Pink,selectedTextColor=Pink,indicatorColor=Color.Transparent))
    } }) { padding ->
        if (app.tab == 0) SearchScreen(app,Modifier.padding(padding),(padding.calculateBottomPadding()-padding.calculateTopPadding())/2) else key(app.sessionRevision) { FollowingScreen(app,Modifier.padding(padding)) }
    }
}
@Composable private fun SearchField(app: AppModel,modifier: Modifier = Modifier) {
    val focus = LocalFocusManager.current
    OutlinedTextField(value=app.keyword,onValueChange={ app.keyword=it },modifier=modifier.fillMaxWidth().heightIn(min=52.dp),shape=RoundedCornerShape(100),singleLine=true,placeholder={ Text("搜索视频、UP主或BV号",color=Muted,fontSize=14.sp,maxLines=1,overflow=TextOverflow.Ellipsis) },leadingIcon={ Icon(Icons.Rounded.Search,null,tint=Muted) },trailingIcon={
        if (app.keyword.isNotEmpty()) IconButton(onClick={ app.keyword=""; app.searched=false }) { Icon(Icons.Rounded.Close,"清空搜索") }
    },keyboardOptions=KeyboardOptions(imeAction=ImeAction.Search),keyboardActions=KeyboardActions(onSearch={ focus.clearFocus(); app.search() }),colors=OutlinedTextFieldDefaults.colors(unfocusedBorderColor=Color(0xffe5e6eb),focusedBorderColor=Pink,unfocusedContainerColor=Soft,focusedContainerColor=Color.White))
}
@Composable private fun SearchScreen(app: AppModel,modifier: Modifier,centerCorrection: androidx.compose.ui.unit.Dp) {
    val focus = LocalFocusManager.current
    if (!app.searched) {
        // The search field itself is centered in the window, not the combined logo and subtitle group.
        Box(modifier.fillMaxSize().clickable(indication=null,interactionSource=remember { androidx.compose.foundation.interaction.MutableInteractionSource() }) { focus.clearFocus() }) {
            Column(Modifier.align(Alignment.Center).offset(y=centerCorrection-112.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                Row(verticalAlignment=Alignment.CenterVertically) { Icon(painterResource(R.drawable.brand_playback),null,Modifier.size(40.dp),tint=Pink); Spacer(Modifier.width(10.dp)); Text("Bilight",fontSize=34.sp,fontWeight=FontWeight.Bold) }
                Text("搜你所想，看你所选",Modifier.padding(top=12.dp),fontSize=15.sp,color=Muted,maxLines=1)
            }
            SearchField(app,Modifier.align(Alignment.Center).offset(y=centerCorrection).padding(horizontal=28.dp))
        }
    } else Column(modifier) {
        val revision=app.searchRevision
        val searchList=key(revision) { rememberLazyListState(app.searchIndex,app.searchOffset) }
        DisposableEffect(searchList) { onDispose { if (app.searchRevision==revision) { app.searchIndex=searchList.firstVisibleItemIndex; app.searchOffset=searchList.firstVisibleItemScrollOffset } } }
        SearchField(app,Modifier.padding(horizontal=16.dp,vertical=8.dp))
        TabRow(if (app.searchUsers) 1 else 0) { listOf("视频","UP主").forEachIndexed { i,label -> Tab(selected=app.searchUsers==(i==1),onClick={ app.searchUsers=i==1; app.search() },text={ Text(label) }) } }
        LazyColumn(state=searchList,modifier=Modifier.fillMaxSize(),contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(18.dp)) {
            if (app.searchUsers) items(app.searchItems.filterIsInstance<User>(),key={ it.mid }) { UserRow(app,it) }
            else items(app.searchItems.filterIsInstance<Video>().chunked(2)) { row -> VideoRow(app,row) }
            if (!app.searchBusy && app.searchItems.isEmpty() && app.searchError==null) item { Text("没有找到相关内容",Modifier.padding(24.dp),color=Muted) }
            item { PageMore(app.searchBusy,app.searchMore,app.searchError) { app.search(false) } }
        }
    }
}
@Composable fun UserRow(app: AppModel,user: User) {
    Row(Modifier.fillMaxWidth().clickable { app.open(Route.Creator(user)) }.padding(vertical=8.dp),verticalAlignment=Alignment.CenterVertically) {
        Avatar(user,44); Column(Modifier.weight(1f).padding(horizontal=12.dp)) { Text(user.name,fontWeight=FontWeight.Medium); if (user.sign.isNotEmpty()) Text(user.sign,fontSize=12.sp,color=Muted,maxLines=2,overflow=TextOverflow.Ellipsis) }; FollowButton(app,user.mid)
    }
}
@Composable fun VideoRow(app: AppModel,videos: List<Video>) {
    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(12.dp)) { videos.forEach { video -> Box(Modifier.weight(1f)) { VideoCard(video) { app.open(Route.Watch(video.bvid)) } } }; if (videos.size==1) Spacer(Modifier.weight(1f)) }
}
@Composable private fun FollowingScreen(app: AppModel,modifier: Modifier) {
    val revision=app.sessionRevision
    val list = rememberLazyListState(app.feedIndex,app.feedOffset)
    var userScrolled by remember { mutableStateOf(false) }
    val connection = remember { object: NestedScrollConnection { override fun onPreScroll(available: Offset,source: NestedScrollSource): Offset { if (source==NestedScrollSource.UserInput && available.y < 0) userScrolled=true; return Offset.Zero } } }
    LaunchedEffect(app.user?.mid) { if (app.user!=null && !app.feedLoaded) app.loadFeed() }
    LaunchedEffect(list) {
        snapshotFlow {
            userScrolled && app.feedMore && !app.feedBusy && app.feedError==null &&
                (list.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1) >= (app.following.size-2).coerceAtLeast(0)
        }.collect { ready -> if (ready) { userScrolled=false;app.loadFeed() } }
    }
    DisposableEffect(Unit) { onDispose { if (app.sessionRevision==revision) { app.feedIndex=list.firstVisibleItemIndex; app.feedOffset=list.firstVisibleItemScrollOffset; app.feedAnchor=app.following.getOrNull(list.firstVisibleItemIndex)?.id } } }
    Column(modifier) {
        Text("我的关注",Modifier.padding(horizontal=20.dp,vertical=12.dp),fontSize=25.sp,fontWeight=FontWeight.Bold)
        Box(Modifier.fillMaxWidth().height(8.dp).background(Soft))
        if (app.user == null) { Column(Modifier.fillMaxSize(),Arrangement.Center,Alignment.CenterHorizontally) { Text("登录后查看关注动态",color=Muted); TextButton(onClick={ app.showLogin=true }) { Text("登录B站") } }; return }
        PullToRefreshBox(isRefreshing=app.feedBusy && app.feedLoaded,onRefresh={ userScrolled=false; app.loadFeed(true) }) {
            LazyColumn(state=list,modifier=Modifier.fillMaxSize().nestedScroll(connection)) {
                items(app.following,key={ it.id }) { PostCard(app,it); Box(Modifier.fillMaxWidth().height(8.dp).background(Soft)) }
                if (app.feedLoaded && app.following.isEmpty() && !app.feedMore && app.feedError==null) item { Text("暂无关注动态",Modifier.padding(24.dp),color=Muted) }
                item { PageMore(app.feedBusy,app.feedMore,app.feedError) { userScrolled=false; app.loadFeed() } }
            }
        }
    }
}
@Composable fun PostCard(app: AppModel,post: Post,nested: Boolean = false,detail: Boolean = false) {
    val expanded=app.expandedPosts[post.id]==true
    var overflowing by remember(post.id) { mutableStateOf(false) }
    var gallery by remember { mutableStateOf<Int?>(null) }
    var menu by remember { mutableStateOf(false) }
    val context=LocalContext.current
    fun share() { runCatching { context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT,"https://t.bilibili.com/${post.id}"),"分享动态链接")) }.onFailure { app.error="暂无可用于分享的应用。" } }
    Column(Modifier.fillMaxWidth().background(if (nested) Soft else Color.White).padding(if (nested) 12.dp else 16.dp)) {
        Row(verticalAlignment=Alignment.CenterVertically) {
            Avatar(post.author,36) { app.open(Route.Creator(post.author)) }
            Column(Modifier.weight(1f).padding(start=10.dp)) { Text(post.author.name,fontSize=14.sp,fontWeight=FontWeight.SemiBold,modifier=Modifier.clickable { app.open(Route.Creator(post.author)) }); Text(java.text.SimpleDateFormat("M月d日 HH:mm",java.util.Locale.CHINA).format(java.util.Date(post.published*1000))+" ${post.action}",fontSize=11.sp,color=Muted) }
            if (!nested) Box {
                IconButton(onClick={ menu=true }) { Icon(Icons.Rounded.MoreHoriz,"动态操作",tint=Muted) }
                DropdownMenu(menu,onDismissRequest={ menu=false }) {
                    if (!detail) DropdownMenuItem(text={ Text("查看动态") },onClick={ menu=false; app.open(Route.Dynamic(post)) })
                    DropdownMenuItem(text={ Text("分享链接") },onClick={ menu=false; share() })
                }
            }
        }
        if (post.title.isNotEmpty()) Text(post.title,fontWeight=FontWeight.SemiBold,modifier=Modifier.padding(top=12.dp))
        if (post.text.isNotEmpty()) { Text(post.text,maxLines=if (detail || expanded) Int.MAX_VALUE else 5,overflow=TextOverflow.Ellipsis,modifier=Modifier.padding(top=10.dp),fontSize=15.sp,lineHeight=23.sp,onTextLayout={ if (!expanded) overflowing=it.hasVisualOverflow }); if (!detail && (overflowing || expanded)) TextButton(onClick={ app.expandedPosts[post.id]=!expanded },modifier=Modifier.heightIn(min=44.dp),contentPadding=PaddingValues(0.dp)) { Text(if (expanded) "收起" else "展开") } }
        post.video?.let { video -> Spacer(Modifier.height(10.dp)); VideoCard(video) { app.open(Route.Watch(video.bvid)) } }
        if (post.pictures.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            if (post.pictures.size==1) { val image=post.pictures.first(); RemoteImage(image.url,"查看大图",Modifier.fillMaxWidth().aspectRatio(if (image.width>0 && image.height>0) (image.width.toFloat()/image.height).coerceIn(.75f,1.8f) else 1f).clip(RoundedCornerShape(8.dp)).clickable { gallery=post.pictures.indexOf(image) }) }
            else {
                val columns=if (post.pictures.size in listOf(2,4)) 2 else 3
                post.pictures.take(9).chunked(columns).forEach { images -> Row(Modifier.fillMaxWidth().padding(bottom=4.dp),horizontalArrangement=Arrangement.spacedBy(4.dp)) {
                    images.forEach { image -> Box(Modifier.weight(1f).aspectRatio(1f).clip(RoundedCornerShape(5.dp)).clickable { gallery=post.pictures.indexOf(image) }) {
                        RemoteImage(image.url,"查看第${post.pictures.indexOf(image)+1}张图片",Modifier.fillMaxSize())
                        if (post.pictures.indexOf(image)==8 && post.pictures.size>9) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha=.45f)),contentAlignment=Alignment.Center) { Text("+${post.pictures.size-9}",color=Color.White,fontSize=24.sp) }
                    } }
                    repeat(columns-images.size) { Spacer(Modifier.weight(1f)) }
                } }
            }
        }
        post.original?.let { Spacer(Modifier.height(12.dp)); PostCard(app,it,nested=true,detail=detail) }
        post.unavailable?.let { Text(it,Modifier.padding(top=12.dp),color=Muted,fontSize=13.sp) }
        post.link?.let { link -> Column(Modifier.fillMaxWidth().background(Soft,RoundedCornerShape(7.dp)).padding(12.dp)) {
            Row { link.cover?.let { RemoteImage(it,link.title,Modifier.size(76.dp).clip(RoundedCornerShape(5.dp))); Spacer(Modifier.width(10.dp)) }
                Column(Modifier.weight(1f)) { Text(link.title,fontSize=14.sp,fontWeight=FontWeight.Medium); Text(link.summary,Modifier.padding(top=6.dp),fontSize=12.sp,color=Muted,maxLines=if (detail) Int.MAX_VALUE else 3,overflow=TextOverflow.Ellipsis); Text(link.label,Modifier.padding(top=6.dp),fontSize=10.sp,color=Blue) }
            }
            if (detail && link.url!=null) TextButton(onClick={ runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,android.net.Uri.parse(link.url))) }.onFailure { app.error="暂无可打开原文的应用。" } }) { Text("打开原文") }
            else if (!detail) TextButton(onClick={ app.open(Route.Dynamic(post)) }) { Text("查看动态") }
        } }
        if (!nested) Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
            TextButton(onClick=::share) { Icon(Icons.Rounded.Share,"分享动态链接",Modifier.size(17.dp),tint=Muted); Text(if (post.forwards>0) count(post.forwards) else "分享",color=Muted,fontSize=12.sp) }
            Spacer(Modifier.weight(1f))
            if (post.commentType>0) {
                if (detail) Row(verticalAlignment=Alignment.CenterVertically) { Icon(Icons.Rounded.ChatBubbleOutline,"${post.comments}条评论",Modifier.size(17.dp),tint=Muted); Text(if (post.comments>0) count(post.comments) else "评论",color=Muted,fontSize=12.sp) }
                else TextButton(onClick={ app.open(Route.Dynamic(post)) }) { Icon(Icons.Rounded.ChatBubbleOutline,"查看评论，共${post.comments}条",Modifier.size(17.dp),tint=Muted); Text(if (post.comments>0) count(post.comments) else "评论",color=Muted,fontSize=12.sp) }
            }
            Spacer(Modifier.weight(1f)); Row(Modifier.semantics(mergeDescendants=true) { contentDescription="${post.likes}赞"+(if (post.liked) "，已点赞" else "") },verticalAlignment=Alignment.CenterVertically) { Icon(Icons.Rounded.ThumbUpOffAlt,null,Modifier.size(17.dp),tint=if (post.liked) Pink else Muted); Text(if (post.likes>0) count(post.likes) else "赞",Modifier.padding(start=5.dp),color=if (post.liked) Pink else Muted,fontSize=12.sp) }
        }
    }
    gallery?.let { PostGallery(post.pictures,it) { gallery=null } }
}
@Composable private fun AccountDialog(app: AppModel) {
    var frequent by remember { mutableStateOf<List<User>?>(null) }; var error by remember { mutableStateOf<String?>(null) }; var refresh by remember { mutableIntStateOf(0) }
    LaunchedEffect(app.user?.mid,refresh) { try { frequent=app.repository.people(1,true).items.take(8); error=null } catch (e: CancellationException) { throw e } catch (e: Exception) { error=e.message } }
    ModalBottomSheet(onDismissRequest={ app.showAccount=false },sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),dragHandle=null) {
      Column(Modifier.weight(1f,fill=false).fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()) {
        app.user?.let { user -> Row(Modifier.padding(20.dp).clickable { app.open(Route.Creator(user)) },verticalAlignment=Alignment.CenterVertically) { Avatar(user,48); Text(user.name,Modifier.weight(1f).padding(start=12.dp),maxLines=2,overflow=TextOverflow.Ellipsis,fontSize=20.sp,fontWeight=FontWeight.SemiBold) } }
        listOf("我的关注的人" to Route.People(false),"我的收藏" to Route.Favorites,"我的下载" to Route.Downloads,"常访问的UP主" to Route.People(true)).forEach { (label,route) -> TextButton(onClick={ app.open(route) },modifier=Modifier.fillMaxWidth().heightIn(min=52.dp),contentPadding=PaddingValues(horizontal=22.dp)) { Text(label,Modifier.weight(1f),color=MaterialTheme.colorScheme.onSurface); Icon(Icons.Rounded.ChevronRight,null,tint=Muted) } }
        if (frequent==null && error==null) Loading("正在读取常访问")
        ErrorNotice(error) { refresh++ }
        frequent?.let { people -> LazyRow(contentPadding=PaddingValues(horizontal=20.dp),horizontalArrangement=Arrangement.spacedBy(16.dp)) { items(people,key={ it.mid }) { person -> Column(Modifier.width(62.dp).clickable { app.open(Route.Creator(person)) },horizontalAlignment=Alignment.CenterHorizontally) { Avatar(person,52); Text(person.name,Modifier.padding(top=8.dp),fontSize=11.sp,maxLines=1,overflow=TextOverflow.Ellipsis) } } } }
        TextButton(onClick=app::logout,modifier=Modifier.padding(10.dp)) { Text("退出登录",color=Muted) }
      }
    }
}

internal class Paging<T> {
    val items = mutableStateListOf<T>(); var busy by mutableStateOf(false); var error by mutableStateOf<String?>(null); var more by mutableStateOf(true); var page by mutableIntStateOf(0); var cursor: String?=null
    suspend fun load(reset: Boolean = false, read: suspend (Int,String?) -> Page<T>) {
        if (busy || !reset && !more) return
        busy=true; error=null
        try {
            val result=read(if (reset) 1 else page+1,if (reset) null else cursor)
            if (reset) items.clear()
            items.addAll(result.items); more=result.more; cursor=result.cursor; page=if (reset) 1 else page+1
        } catch (e: CancellationException) { throw e } catch (e: Exception) { error=e.message } finally { busy=false }
    }
}
@Composable private fun <T> Paged(title: String,app: AppModel,identity: Any,read: suspend (Int,String?) -> Page<T>,item: @Composable (T) -> Unit) {
    val paging = remember(identity,app.user?.mid) { Paging<T>() }; val scope=rememberCoroutineScope()
    LaunchedEffect(identity,app.user?.mid) { paging.load(read=read) }
    Column(Modifier.safeDrawingPadding()) { SectionTitle(title,app::back); LazyColumn(contentPadding=PaddingValues(horizontal=16.dp,vertical=12.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) { items(paging.items) { item(it) }; if (paging.page>0 && !paging.busy && paging.items.isEmpty() && paging.error==null) item { EmptyNotice("暂无内容") }; item { PageMore(paging.busy,paging.more,paging.error) { scope.launch { paging.load(read=read) } } } } }
}
@Composable private fun PeopleScreen(app: AppModel,frequent: Boolean) { Paged(if (frequent) "常访问的UP主" else "我的关注的人",app,frequent,{ page,_ -> app.repository.people(page,frequent) }) { UserRow(app,it) } }
@Composable private fun CreatorScreen(app: AppModel,user: User) {
    var mode by rememberSaveable(user.mid) { mutableIntStateOf(0) }
    var info by remember(user.mid) { mutableStateOf(user) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(user.mid) { try { info=app.repository.creator(user.mid) } catch (e: Exception) { error=e.message } }
    Column(Modifier.safeDrawingPadding()) {
        SectionTitle(info.name,app::back)
        Row(Modifier.padding(20.dp),verticalAlignment=Alignment.CenterVertically) { Avatar(info,56); Column(Modifier.weight(1f).padding(horizontal=12.dp)) { Text(info.name,fontSize=20.sp,fontWeight=FontWeight.Bold); Text(info.sign,fontSize=12.sp,color=Muted,maxLines=3,overflow=TextOverflow.Ellipsis) }; FollowButton(app,info.mid) }
        ErrorNotice(error)
        TabRow(mode) { listOf("投稿","合集和列表").forEachIndexed { i,label -> Tab(selected=mode==i,onClick={ mode=i },text={ Text(label) }) } }
        if (mode==0) {
            val paging=remember(user.mid) { Paging<Video>() }; val scope=rememberCoroutineScope()
            LaunchedEffect(user.mid) { paging.load { p,_ -> app.repository.creatorVideos(info,p) } }
            LazyColumn(contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(20.dp)) { items(paging.items.chunked(2)) { VideoRow(app,it) }; item { PageMore(paging.busy,paging.more,paging.error) { scope.launch { paging.load { p,_ -> app.repository.creatorVideos(info,p) } } } } }
        } else {
            val paging=remember(user.mid) { Paging<Collection>() }; val scope=rememberCoroutineScope()
            LaunchedEffect(user.mid) { paging.load { p,_ -> app.repository.collections(user.mid,p) } }
            LazyColumn(contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) { items(paging.items) { c -> Row(Modifier.clickable { app.open(Route.Catalog(info,c)) },verticalAlignment=Alignment.CenterVertically) { RemoteImage(c.cover,c.title,Modifier.size(100.dp,64.dp).clip(RoundedCornerShape(6.dp))); Column(Modifier.padding(start=12.dp)) { Text(c.title); Text("${if (c.series) "列表" else "合集"} · ${c.total}个视频",fontSize=12.sp,color=Muted) } } }; item { PageMore(paging.busy,paging.more,paging.error) { scope.launch { paging.load { p,_ -> app.repository.collections(user.mid,p) } } } } }
        }
    }
}
@Composable private fun CatalogScreen(app: AppModel,route: Route.Catalog) { Paged(route.collection.title,app,route.collection,{ page,_ -> val result=app.repository.collection(route.user,route.collection,page); Page(result.items.chunked(2),result.more) }) { VideoRow(app,it) } }
@Composable private fun FavoritesScreen(app: AppModel) {
    var collected by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.safeDrawingPadding()) { SectionTitle("我的收藏",app::back); TabRow(if (collected) 1 else 0) { listOf("我创建的","我收藏的").forEachIndexed { i,label -> Tab(selected=collected==(i==1),onClick={ collected=i==1 },text={ Text(label) }) } }; key(collected) {
        val paging=remember { Paging<Folder>() }; val scope=rememberCoroutineScope(); LaunchedEffect(Unit) { paging.load { p,_ -> app.repository.folders(collected,p) } }
        LazyColumn(contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(18.dp)) { items(paging.items) { folder -> Row(Modifier.fillMaxWidth().clickable { app.open(Route.Favorite(folder)) }) { RemoteImage(folder.cover,folder.title,Modifier.size(96.dp,64.dp).clip(RoundedCornerShape(8.dp))); Column(Modifier.padding(start=12.dp)) { Text(folder.title); Text("${folder.count}个内容${if (folder.private) " · 私密" else ""}",fontSize=12.sp,color=Muted) } } }; if (paging.page>0 && !paging.busy && paging.items.isEmpty() && paging.error==null) item { EmptyNotice("暂无收藏夹") }; item { PageMore(paging.busy,paging.more,paging.error) { scope.launch { paging.load { p,_ -> app.repository.folders(collected,p) } } } } }
    } }
}
@Composable private fun FolderScreen(app: AppModel,folder: Folder) { Paged(folder.title,app,folder.id,{ page,_ -> val result=app.repository.folderVideos(folder,page); Page(result.items.chunked(2),result.more) }) { VideoRow(app,it) } }
@Composable private fun HistoryScreen(app: AppModel) {
    val paging=remember(app.user?.mid) { Paging<History>() }
    val scope=rememberCoroutineScope()
    val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    suspend fun load(refresh: Boolean = false) {
        app.retryHistory(); val version=app.http.generation
        paging.load(refresh) { _,cursor -> app.repository.history(cursor).also { app.http.check(version) } }
    }
    LaunchedEffect(app.user?.mid) { load() }
    DisposableEffect(lifecycle) {
        val observer=androidx.lifecycle.LifecycleEventObserver { _,event -> if (event==androidx.lifecycle.Lifecycle.Event.ON_START) scope.launch { load(true) } }
        lifecycle.addObserver(observer); onDispose { lifecycle.removeObserver(observer) }
    }
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        SectionTitle("我的历史",app::back)
        ErrorNotice(app.historyError,app::retryHistory)
        PullToRefreshBox(isRefreshing=paging.busy && paging.items.isNotEmpty(),onRefresh={ scope.launch { load(true) } }) {
            LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(18.dp)) {
                items(paging.items,key={ it.video.bvid }) { history -> Box(Modifier.fillMaxWidth().clickable { app.open(Route.Watch(history.video.bvid,history.page,if (history.completed) 0 else history.progress,cid=history.cid.takeIf { it>0 })) }) {
                    MediaSummaryLayout(130,thumbnail={ RemoteImage(history.video.cover,history.video.title,it.clip(RoundedCornerShape(6.dp))) }) {
                        Text(history.video.title,maxLines=3,overflow=TextOverflow.Ellipsis,fontSize=14.sp)
                        Text(history.video.owner.name,color=Muted,fontSize=12.sp)
                        Text("P${history.page} · "+(if (history.completed) "已看完" else "看到 ${clock(history.progress)}"),color=Muted,fontSize=12.sp)
                        Text(java.text.SimpleDateFormat("M月d日 HH:mm",java.util.Locale.CHINA).format(java.util.Date(history.viewedAt*1000)),color=Muted,fontSize=11.sp)
                    }
                } }
                if (!paging.busy && paging.items.isEmpty() && paging.error==null) item { Text("暂无播放记录",color=Muted) }
                item { PageMore(paging.busy,paging.more,paging.error) { scope.launch { load() } } }
            }
        }
    }
}
@Composable private fun DynamicScreen(app: AppModel,post: Post) {
    val paging=remember(post.id) { Paging<Comment>() }; val scope=rememberCoroutineScope()
    LaunchedEffect(post.id) { if (post.commentType>0 && post.commentId!=null) paging.load { _,cursor -> app.repository.comments(post.commentId,post.commentType,cursor) } }
    Column(Modifier.safeDrawingPadding()) { SectionTitle("动态",app::back); LazyColumn { item { PostCard(app,post,detail=true) }; items(paging.items) { CommentRow(app,it) }; item { PageMore(paging.busy,paging.more && post.commentType>0,paging.error) { scope.launch { paging.load { _,cursor -> app.repository.comments(post.commentId ?: post.id,post.commentType,cursor) } } } } } }
}
@Composable fun CommentRow(app: AppModel,comment: Comment) { Row(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=14.dp)) { Avatar(comment.user,32) { app.open(Route.Creator(comment.user)) }; Column(Modifier.padding(start=10.dp)) { Text(comment.user.name,color=Muted,fontSize=12.sp); Text(comment.text,Modifier.padding(top=5.dp),fontSize=14.sp,lineHeight=22.sp); if (comment.likes>0) Text("${count(comment.likes)}赞",fontSize=11.sp,color=Muted) } } }

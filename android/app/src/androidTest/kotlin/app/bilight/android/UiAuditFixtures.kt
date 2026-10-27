package app.bilight.android

import android.content.Context
import app.bilight.android.core.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/** Offline public snapshots and an isolated account; every API write is intercepted in memory. */
internal class UiAuditFixtures(private val context: Context) {
    val uid=900000001L
    val root=File(context.cacheDir,"ui-audit-assets")
    val snapshot=JSONObject(File(root,"public-content.json").readText())
    val creators=snapshot.rows("creators").map { r -> User(r.getLong("mid"),r.getString("name"),image(r.getString("avatar"))) }
    val videos=snapshot.rows("videos").map { r -> Video(r.getString("bvid"),r.getLong("aid"),r.getString("title"),image(r.getString("cover")),r.getLong("duration"),r.getLong("publishedAt"),creators.first { it.mid==r.getLong("ownerMid") },r.obj("statistics").optLong("view"),1920,1080) }
    val requests=CopyOnWriteArrayList<String>()
    val blocked=mutableSetOf<String>()
    var empty=false
    var portrait=false
    private val clip=File(root,"fixture.mp4").also { if (!it.exists()) encodedFixture(it,false) }.readBytes()
    private fun image(path: String)="https://i0.hdslb.com/ui-audit/${path.substringAfterLast('/')}"
    fun user(value: User)=JSONObject().put("mid",value.mid).put("name",value.name).put("uname",value.name).put("face",value.avatar).put("sign","用影像记录生活，分享认真观察后的故事。").put("attribute",2)
    fun video(value: Video)=JSONObject().put("bvid",value.bvid).put("aid",value.aid).put("title",value.title).put("pic",value.cover).put("cover",value.cover).put("duration",value.duration).put("pubdate",value.published).put("owner",user(value.owner)).put("upper",user(value.owner)).put("play",value.views).put("type",2).put("attr",0).put("dimension",JSONObject().put("width",value.width).put("height",value.height))
    fun folder(id: Int=101)=JSONObject().put("id",id).put("mid",uid).put("title",if (id==101) "电影、旅行与值得慢慢看的故事" else "以后再看：摄影与生活灵感").put("media_count",28).put("max_count",50000).put("attr",if(id==101) 1 else 0).put("fav_state",if(id==101) 1 else 0).put("cover",videos.first().cover)
    fun posts(): List<Post> {
        val longText="最近在整理旅行中拍摄的照片。比起不停赶路，我更喜欢停下来观察街道、光线和人们的日常。\n".repeat(7)
        return listOf(
            Post("10001",creators[0],1793000000,"发布了图文",longText,"这次，慢一点看看身边的风景",pictures=videos.take(4).map { Picture(it.cover!!,1920,1080) },commentId="10001",commentType=17,comments=128,likes=3862),
            Post("10002",creators[1],1792990000,"投稿了视频","", "",video=videos[2],commentId="10002",commentType=1,comments=936,likes=22800),
            Post("10003",creators[2],1792980000,"发布了动态",longText,"",commentId="10003",commentType=17,comments=72,likes=1123),
            Post("10004",creators[1],1792970000,"转发了动态","一段很值得反复看的影像。","",original=Post("10005",videos[0].owner,1792960000,"投稿了视频","","",video=videos[0]),commentId="10004",commentType=17,likes=1682),
            Post("10006",creators[0],1792950000,"发布了专栏","关于影像创作的一些观察。","",link=PostLink("让故事比器材更重要",longText,videos[1].cover,"https://www.bilibili.com/read/cv10006","专栏"),commentId="10006",commentType=12,likes=762),
            Post("10007",creators[2],1792940000,"转发了动态","记录曾经看到的内容。","",unavailable="原动态已失效或暂时无法查看",likes=12)
        )
    }
    private fun api(request: Request): JSONObject {
        val path=request.url.encodedPath; requests+=request.method+" "+path
        if (path in blocked) return JSONObject().put("code",-352).put("message","暂时无法读取，请稍后重试")
        val list=if(empty) emptyList() else videos
        val data: JSONObject=when(path) {
            "/x/web-interface/nav" -> user(User(uid,"Bilight 演示账号",creators[0].avatar)).put("isLogin",true).put("wbi_img",JSONObject().put("img_url","https://i0.hdslb.com/abcdefghijklmnopqrstuvwxyz012345.png").put("sub_url","https://i0.hdslb.com/6789abcdefghijklmnopqrstuvwxyz01.png"))
            "/x/frontend/finger/spi" -> JSONObject().put("b_3","fixture-official-response-only").put("b_4","fixture-response-only")
            "/x/web-interface/wbi/search/type" -> JSONObject().put("numPages",1).put("result",JSONArray(if(request.url.queryParameter("search_type")=="bili_user") { if(empty) emptyList<JSONObject>() else creators.map(::user) } else list.map(::video)))
            "/x/relation" -> JSONObject().put("attribute",2)
            "/x/relation/relations" -> JSONObject().apply { creators.forEach { put(it.mid.toString(),JSONObject().put("attribute",2)) } }
            "/x/relation/followings" -> JSONObject().put("total",if(empty) 0 else creators.size).put("list",JSONArray(if(empty) emptyList<JSONObject>() else creators.map(::user)))
            "/x/polymer/web-dynamic/v1/feed/all" -> JSONObject().put("has_more",0).put("offset","").put("items",JSONArray())
            "/x/space/wbi/acc/info" -> user(creators.firstOrNull { it.mid.toString()==request.url.queryParameter("mid") } ?: creators[0])
            "/x/space/wbi/arc/search" -> JSONObject().put("list",JSONObject().put("vlist",JSONArray(list.map(::video)))).put("page",JSONObject().put("count",list.size))
            "/x/polymer/web-space/seasons_series_list" -> JSONObject().put("items_lists",JSONObject().put("seasons_list",JSONArray().put(JSONObject().put("meta",JSONObject().put("season_id",201).put("mid",creators[0].mid).put("name","旅行影像：在路上的每一个故事").put("cover",videos[0].cover).put("total",8)))).put("series_list",JSONArray().put(JSONObject().put("meta",JSONObject().put("series_id",202).put("mid",creators[0].mid).put("name","创作笔记与摄影基础").put("cover",videos[1].cover).put("total",12)))).put("page",JSONObject().put("total",2).put("page_size",12)))
            "/x/polymer/web-space/seasons_archives_list" -> JSONObject().put("meta",JSONObject().put("season_id",201).put("mid",creators[0].mid)).put("archives",JSONArray(list.map(::video))).put("page",JSONObject().put("total",list.size).put("page_size",30))
            "/x/v3/fav/folder/created/list", "/x/v3/fav/folder/collected/list", "/x/v3/fav/folder/created/list-all" -> JSONObject().put("count",if(empty) 0 else 2).put("has_more",false).put("list",JSONArray(if(empty) emptyList<JSONObject>() else listOf(folder(),folder(102))))
            "/x/v3/fav/resource/list" -> folder().let { JSONObject().put("info",it).put("has_more",false).put("medias",JSONArray(list.map(::video))) }
            "/x/web-interface/history/cursor" -> JSONObject().put("list",JSONArray(list.take(4).mapIndexed { i,v -> JSONObject().put("title",v.title).put("cover",v.cover).put("author_mid",v.owner.mid).put("author_name",v.owner.name).put("author_face",v.owner.avatar).put("duration",v.duration).put("view_at",1793000000-i*3600).put("progress",if(i==1) -1 else 41).put("history",JSONObject().put("business","archive").put("bvid",v.bvid).put("oid",v.aid).put("cid",30001+i).put("page",1)) })).put("cursor",JSONObject().put("max",0).put("view_at",0))
            "/x/web-interface/wbi/view" -> {
                val v=videos.firstOrNull { it.bvid==request.url.queryParameter("bvid") } ?: videos[0]
                video(v).put("copyright",1).put("desc","在路上认真记录，也留一点时间给自己。\n这是用于界面验收的公开内容快照。").put("stat",JSONObject().put("view",v.views).put("like",178495).put("coin",65515).put("favorite",49647)).put("pages",JSONArray((1..2).map { JSONObject().put("cid",30000+it).put("page",it).put("part",if(it==1) "正片：一段完整的旅行记录" else "幕后：拍摄与创作笔记").put("duration",120).put("dimension",JSONObject().put("width",if(portrait) 1080 else 1920).put("height",if(portrait) 1920 else 1080)) }))
            }
            "/x/player/wbi/playurl" -> JSONObject().put("quality",80).put("timelength",120000).put("durl",JSONArray().put(JSONObject().put("url","https://audit.bilivideo.com/fixture.mp4")))
            "/x/player/wbi/v2" -> JSONObject().put("subtitle",JSONObject().put("subtitles",JSONArray().put(JSONObject().put("id",1).put("lan","zh-CN").put("lan_doc","中文（自动生成）").put("subtitle_url","https://i0.hdslb.com/ui-audit/subtitle.json"))))
            "/x/web-interface/archive/relation" -> JSONObject().put("like",false).put("coin",0).put("favorite",true)
            "/x/v2/reply/wbi/main" -> JSONObject().put("cursor",JSONObject().put("is_end",true).put("all_count",2)).put("replies",JSONArray((1..2).map { JSONObject().put("rpid_str","$it").put("member",user(creators[it])).put("content",JSONObject().put("message",if(it==1) "很喜欢这样的节奏。留一点时间认真看完，比一直刷更舒服。" else "画面、声音和故事都很棒，期待下一次更新！")).put("like",128*it) }))
            "/x/v2/history/report" -> JSONObject()
            else -> return JSONObject().put("code",-404).put("message","隔离测试未配置此请求")
        }
        return JSONObject().put("code",0).put("data",data)
    }
    fun client()=OkHttpClient.Builder().addInterceptor { chain ->
        val request=chain.request(); val path=request.url.encodedPath
        val body=when {
            path=="/ui-audit/subtitle.json" -> """{"body":[{"from":0,"to":120,"content":"把时间留给你真正想看的内容。"}]}""".toByteArray()
            path=="/x/v1/dm/list.so" -> "<i><d p=\"0,1,25,16777215\">搜你所想，看你所选</d></i>".toByteArray()
            path.startsWith("/ui-audit/") -> File(root,path.substringAfterLast('/')).readBytes()
            else -> api(request).toString().toByteArray()
        }
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body.toResponseBody((if(path.endsWith(".jpg")) "image/jpeg" else "application/json").toMediaType())).build()
    }.build()
    fun mediaClient()=OkHttpClient.Builder().addInterceptor { chain ->
        val request=chain.request(); check(request.url.host=="audit.bilivideo.com")
        val range=request.header("Range")?.substringAfter("bytes=")?.substringBefore('-')?.toIntOrNull() ?: 0
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(if(range>0) 206 else 200).message("OK").header("Content-Range","bytes $range-${clip.lastIndex}/${clip.size}").body(clip.copyOfRange(range.coerceAtMost(clip.size),clip.size).toResponseBody("video/mp4".toMediaType())).build()
    }.build()
}

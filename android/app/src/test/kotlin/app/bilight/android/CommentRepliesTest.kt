package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CommentRepliesTest {
    private fun repository(handler: (Request) -> JSONObject): BiliRepository {
        val client=OkHttpClient.Builder().addInterceptor { chain ->
            val request=chain.request(); assertEquals("GET",request.method)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(JSONObject().put("code",0).put("data",handler(request)).toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        return BiliRepository(BiliHttp(object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} },client))
    }
    private fun page(number: Int=1,count: Int=21,root: String="289123456789",replyRoot: String=root) = JSONObject()
        .put("page",JSONObject().put("num",number).put("size",20).put("count",count))
        .put("root",JSONObject().put("rpid_str",root).put("oid","1057955152016703512"))
        .put("replies",JSONArray().put(JSONObject().put("rpid_str","289123456790").put("root",replyRoot).put("oid","1057955152016703512").put("content",JSONObject().put("message","Child"))))
    @Test fun readsOnlyTheExplicitPageAndExactDynamicThread() = runBlocking {
        val repo=repository { request ->
            assertEquals("/x/v2/reply/reply",request.url.encodedPath)
            assertEquals("1057955152016703512",request.url.queryParameter("oid"))
            assertEquals("289123456789",request.url.queryParameter("root"))
            assertEquals("17",request.url.queryParameter("type"))
            page(number=request.url.queryParameter("pn")!!.toInt())
        }
        val first=repo.commentReplies("1057955152016703512",17,"289123456789")
        assertEquals(21,first.total); assertTrue(first.more); assertEquals("Child",first.items.first().text)
        assertFalse(repo.commentReplies("1057955152016703512",17,"289123456789",2).more)
    }
    @Test fun rejectsWrongRootsAndFakeEmptyPages() = runBlocking {
        for (data in listOf(page(root="99"),page(replyRoot="99"),page(count=40).put("replies",JSONArray()))) {
            try { repository { data }.commentReplies("1057955152016703512",17,"289123456789"); fail("Must reject incomplete or mismatched thread") }
            catch (_: BiliFailure) {}
        }
    }

    @Test fun preservesEmojiAndOnlyResolvesTrustedEmotesPresentInCommentText() = runBlocking {
        val text = "原生 🐱 [微笑] [无效] [未知]"
        val repo = repository {
            page(count=1).apply {
                getJSONArray("replies").getJSONObject(0).put("content",JSONObject().put("message",text)
                    .put("emote",JSONObject()
                        .put("[微笑]",JSONObject().put("url","//i0.hdslb.com/bfs/emote/smile.png"))
                        .put("[无效]",JSONObject().put("url","https://hdslb.com.example.org/wrong.png"))
                        .put("[其它]",JSONObject().put("url","https://i0.hdslb.com/bfs/emote/other.png"))))
            }
        }
        val comment = repo.commentReplies("1057955152016703512",17,"289123456789").items.single()
        assertEquals(text,comment.text)
        assertEquals(mapOf("[微笑]" to "https://i0.hdslb.com/bfs/emote/smile.png"),comment.emotes)
    }

    private val viewer = User(7,"测试用户",null)
    private val creator = User(8,"测试创作者",null)
    private val video = Video("BV12qnt6VEM1",42,"测试视频",null,30,0,creator,0)
    private val parent = Comment("100",viewer,"父评论",5)
    private val nested = Comment("101",viewer,"子评论",0)
    private fun row(rpid: String,root: String="0",parent: String="0",like: Long=5,action: Int=0,message: String="内容") = JSONObject()
        .put("rpid_str",rpid).put("oid",video.aid).put("type",1).put("root_str",root).put("parent_str",parent)
        .put("like",like).put("action",action).put("mid",viewer.mid)
        .put("member",JSONObject().put("mid",viewer.mid).put("uname",viewer.name))
        .put("content",JSONObject().put("message",message).put("members",JSONArray().put(JSONObject().put("mid",creator.mid).put("uname",creator.name))))

    private suspend fun signedRepository(handler: (Request) -> JSONObject): BiliRepository {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val envelope = when (request.url.encodedPath) {
                "/x/web-interface/nav" -> JSONObject().put("code",0).put("data",JSONObject()
                    .put("mid",viewer.mid).put("uname",viewer.name).put("isLogin",true)
                    .put("wbi_img",JSONObject().put("img_url","https://i0.hdslb.com/${"a".repeat(32)}.png")
                        .put("sub_url","https://i0.hdslb.com/${"b".repeat(32)}.png")))
                else -> handler(request)
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(envelope.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        val http = BiliHttp(object: SecureStore {
            override fun load(): ByteArray? = null
            override fun save(bytes: ByteArray) {}
            override fun clear() {}
        },client)
        http.acceptLogin("SESSDATA=fixture-session; bili_jct=fixture-token; buvid3=fixture-device")
        return BiliRepository(http)
    }
    private fun ok(data: Any = JSONObject.NULL) = JSONObject().put("code",0).put("data",data)
    private fun Request.fields(): Map<String,String> = (body as FormBody).let { form ->
        (0 until form.size).associate { i -> form.name(i) to form.value(i) }
    }

    @Test fun dynamicLikesAndNestedRepliesKeepTheAuthoritativeObjectAndType() = runBlocking {
        val oid = "1057955152016703512"
        val post = Post("1057955152016703513",creator,0,"","","",video=video,commentId=oid,commentType=17)
        val subject = checkNotNull(CommentSubject.dynamic(post))
        var liked = false
        var wrongType = false
        val writes = mutableListOf<String>()
        fun dynamicRow(id: String) = row(id,if (id==nested.id) parent.id else "0",if (id==nested.id) parent.id else "0",
            like=if (liked) 6 else 5,action=if (liked) 1 else 0).put("oid_str",oid).put("type",if(wrongType) 1 else 17)
        val repo = signedRepository { request ->
            when (request.url.encodedPath) {
                "/x/v2/reply/detail" -> {
                    assertEquals(oid,request.url.queryParameter("oid"))
                    assertEquals("17",request.url.queryParameter("type"))
                    ok(JSONObject().put("root",dynamicRow(request.url.queryParameter("root")!!)))
                }
                "/x/v2/reply/action", "/x/v2/reply/add" -> {
                    val fields = request.fields()
                    assertEquals(oid,fields["oid"])
                    assertEquals("17",fields["type"])
                    writes += request.url.encodedPath
                    if (request.url.encodedPath.endsWith("/action")) {
                        assertEquals(nested.id,fields["rpid"])
                        liked = true
                        ok()
                    } else {
                        assertEquals(parent.id,fields["root"])
                        assertEquals(nested.id,fields["parent"])
                        ok(JSONObject().put("reply",dynamicRow("103").put("root_str",parent.id).put("parent_str",nested.id)))
                    }
                }
                else -> error("Unexpected interaction request")
            }
        }
        assertEquals(CommentLikeState(true,6),repo.setCommentLike(subject,nested.id,true))
        assertEquals("103",repo.postComment(subject,"动态回复",emptyList(),CommentTarget(parent,nested)).id)
        wrongType = true
        try { repo.postComment(subject,"拒绝混用评论区",emptyList(),CommentTarget(parent,nested)); fail("Wrong reply type must reject the write") }
        catch (_: BiliFailure) {}
        assertEquals(listOf("/x/v2/reply/action","/x/v2/reply/add"),writes)
    }

    @Test fun followsOfficialMentionSearchAndCommentFormForTopLevelAndNestedReplies() = runBlocking {
        val requests = mutableListOf<Map<String,String>>()
        val repo = signedRepository { request ->
            when (request.url.encodedPath) {
                "/x/v2/reply/at" -> {
                    assertEquals("测试",request.url.queryParameter("keyword"))
                    ok(JSONObject().put("groups",JSONArray().put(JSONObject().put("items",JSONArray().put(
                        JSONObject().put("mid",creator.mid).put("name",creator.name).put("face","https://i0.hdslb.com/portrait.png")
                    )))))
                }
                "/x/v2/reply/detail" -> {
                    val id = request.url.queryParameter("root")
                    assertEquals(video.aid.toString(),request.url.queryParameter("oid"))
                    ok(JSONObject().put("root",if (id=="100") row("100") else row("101","100","100")))
                }
                "/x/v2/reply/add" -> {
                    assertEquals("POST",request.method)
                    assertNotNull(request.url.queryParameter("w_rid"))
                    val form = request.fields()
                    requests += form
                    ok(JSONObject().put("reply",row("10${2+requests.size}",form["root"] ?: "0",form["parent"] ?: "0",message=form.getValue("message"))))
                }
                else -> error("Unexpected interaction request")
            }
        }
        val mention = repo.commentMentionUsers("测试").single()
        assertEquals(creator.mid,mention.mid)
        assertEquals("https://i0.hdslb.com/portrait.png",mention.avatar)
        val message = "先评论 @${creator.name} "
        val top = repo.postVideoComment(video,message,listOf(mention),null)
        assertEquals(message,top.text)
        assertEquals(creator.mid,top.mentions.single().mid)
        assertFalse(requests.first().containsKey("root"))
        assertFalse(requests.first().containsKey("parent"))
        assertEquals(creator.mid,JSONObject(requests.first().getValue("at_name_to_mid")).getLong(creator.name))
        repo.postVideoComment(video,"回复不带提及",listOf(mention),CommentTarget(parent,nested))
        assertEquals("100",requests.last()["root"])
        assertEquals("101",requests.last()["parent"])
        assertEquals(0,JSONObject(requests.last().getValue("at_name_to_mid")).length())
    }

    @Test fun writesLikesOnceAndReturnsTheVerifiedState() = runBlocking {
        var action = 0
        var writes = 0
        var oid = video.aid
        val repo = signedRepository { request ->
            when (request.url.encodedPath) {
                "/x/v2/reply/detail" -> ok(JSONObject().put("root",row("100",action=action,like=5L+action).put("oid",oid)))
                "/x/v2/reply/action" -> {
                    val values = request.fields()
                    assertEquals("100",values["rpid"])
                    assertEquals(video.aid.toString(),values["oid"])
                    assertEquals("1",values["type"])
                    writes++
                    action=values.getValue("action").toInt()
                    ok()
                }
                else -> error("Unexpected interaction request")
            }
        }
        assertEquals(CommentLikeState(true,6),repo.setCommentLike(video,"100",true))
        assertEquals(CommentLikeState(true,6),repo.setCommentLike(video,"100",true))
        assertEquals(CommentLikeState(false,5),repo.setCommentLike(video,"100",false))
        oid = 99
        try { repo.setCommentLike(video,"100",true); fail("Must reject comments from other videos") }
        catch (_: BiliFailure) {}
        assertEquals(2,writes)
    }

    @Test fun commentLikeWaitsForTheRealCountWhenTheStatusArrivesFirst() = runBlocking {
        var writes = 0
        var confirmingReads = 0
        val repo = signedRepository { request ->
            when (request.url.encodedPath) {
                "/x/v2/reply/detail" -> {
                    if (writes>0) confirmingReads++
                    val likes = if (confirmingReads>=2) 12L else 5L
                    ok(JSONObject().put("root",row("100",action=if (writes>0) 1 else 0,like=likes).put("oid",42)))
                }
                "/x/v2/reply/action" -> { writes++; ok() }
                else -> error("Unexpected comment interaction request")
            }
        }
        assertEquals(CommentLikeState(true,12),repo.setCommentLike(video,"100",true))
        assertEquals(1,writes)
        assertEquals(2,confirmingReads)
    }
}

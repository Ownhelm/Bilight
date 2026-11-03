package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CollectedFoldersTest {
    @Test fun collectedBiliimgCoversSurviveDirectoryParsing() = runBlocking {
        val cover="https://archive.biliimg.com/bfs/archive/62e05dd136b5e9ae0d6b7662682229408d44c2d3.jpg"
        fixture({ JSONObject("""{"count":1,"has_more":false,"list":[{"id":100,"mid":7,"title":"合集","media_count":5,"type":21,"cover":"$cover"}]}""") }) { repository ->
            assertEquals(cover,repository.folders(true).items.single().cover)
        }
    }
    private suspend fun fixture(dispatch: (RecordedRequest) -> JSONObject, errorCode: Int = 0, test: suspend (BiliRepository) -> Unit) {
        val server=MockWebServer()
        server.dispatcher=object: Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                assertEquals("GET",request.method)
                val data=if (request.requestUrl!!.encodedPath=="/x/web-interface/nav")
                    JSONObject("""{"isLogin":true,"mid":42,"uname":"隔离测试"}""") else dispatch(request)
                return MockResponse().setBody(JSONObject().put("code",if (request.requestUrl!!.encodedPath=="/x/web-interface/nav") 0 else errorCode).put("message","上游返回错误").put("data",data).toString())
            }
        }
        server.start()
        try {
            val store=object: SecureStore { override fun load(): ByteArray?=null; override fun save(bytes: ByteArray) {}; override fun clear() {} }
            val client=OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val original=chain.request()
                val url=server.url(original.url.encodedPath).newBuilder().encodedQuery(original.url.encodedQuery).build()
                chain.proceed(original.newBuilder().url(url).build()).newBuilder().request(original).build()
            }.build()
            val http=BiliHttp(store,client); http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only")
            test(BiliRepository(http))
        } finally { server.shutdown() }
    }

    @Test fun collectedSeasonOpensItsArchivesInsteadOfAnUnrelatedFolderWithTheSameId() = runBlocking {
        val paths=mutableListOf<String>()
        fixture({ request ->
            val url=request.requestUrl!!; paths+=url.encodedPath
            when (url.encodedPath) {
                "/x/v3/fav/folder/collected/list" -> {
                    assertEquals("42",url.queryParameter("up_mid"))
                    JSONObject("""{"count":1,"has_more":false,"list":[{"id":100,"mid":7,"upper":{"mid":7,"name":"合集作者"},"title":"收藏的合集","media_count":1,"type":21,"state":0}]}""")
                }
                "/x/polymer/web-space/seasons_archives_list" -> {
                    assertEquals("100",url.queryParameter("season_id")); assertEquals("7",url.queryParameter("mid"))
                    assertEquals("2",url.queryParameter("page_num")); assertEquals("false",url.queryParameter("sort_reverse"))
                    JSONObject("""{"meta":{"season_id":100,"mid":7,"name":"收藏的合集","total":61},"page":{"page_num":2,"page_size":30,"total":61},"archives":[{"aid":1,"bvid":"BV1NGZtBwELa","title":"合集里的视频"}]}""")
                }
                // The two upstream ID namespaces can collide; the folder belongs to somebody else.
                "/x/v3/fav/resource/list" -> JSONObject("""{"info":{"id":100,"mid":99,"title":"无关收藏夹","media_count":0},"medias":[],"has_more":false}""")
                else -> error("Unexpected endpoint: ${url.encodedPath}")
            }
        }) { repository ->
            val folder=repository.folders(true).items.single()
            val page=repository.folderVideos(folder,2)
            assertEquals("合集里的视频",page.items.single().title); assertEquals(7L,page.items.single().owner.mid)
            assertEquals("合集作者",page.items.single().owner.name)
            assertTrue(page.more); assertFalse(paths.contains("/x/v3/fav/resource/list"))
        }
    }

    @Test fun mixedCollectedEntriesKeepTheirTypeOwnerAndAvailability() = runBlocking {
        fixture({ request ->
            assertEquals("/x/v3/fav/folder/collected/list",request.requestUrl!!.encodedPath)
            JSONObject("""{"count":21,"has_more":true,"list":[{"id":100,"mid":0,"title":"创建者不可用的合集","media_count":5,"type":21},{"id":101,"mid":7,"title":"收藏夹","media_count":2,"type":11},{"id":102,"upper":{"mid":8},"title":"合集","media_count":3,"type":21},{"id":103,"mid":9,"title":"失效收藏夹","media_count":4,"type":11,"state":1}]}""")
        }) { repository ->
            val page=repository.folders(true)
            assertEquals(listOf(100L,101L,102L,103L),page.items.map { it.id }); assertTrue(page.more)
            assertEquals(listOf(21,11,21,11),page.items.map { it.type }); assertEquals(8L,page.items[2].mid)
            assertEquals(listOf(true,false,false,true),page.items.map { it.unavailable })
            for (folder in listOf(page.items.first(),page.items.last())) {
                try { repository.folderVideos(folder,1); fail("Unavailable entries must not request contents") }
                catch (e: BiliFailure) { assertEquals("FOLDER_UNAVAILABLE",e.code) }
            }
        }
    }

    @Test fun ordinaryFavoriteFoldersStillUseTheirOwnEndpointAndPagination() = runBlocking {
        fixture({ request ->
            val url=request.requestUrl!!
            when (url.encodedPath) {
                "/x/v3/fav/folder/created/list" -> JSONObject("""{"count":1,"has_more":false,"list":[{"id":101,"mid":42,"title":"我的收藏夹","media_count":21}]}""")
                "/x/v3/fav/resource/list" -> {
                    assertEquals("101",url.queryParameter("media_id")); assertEquals("2",url.queryParameter("pn"))
                    JSONObject("""{"info":{"id":101,"mid":42,"title":"我的收藏夹","media_count":21},"medias":[{"id":1,"bv_id":"BV1NGZtBwELa","title":"收藏视频","type":2,"attr":0,"upper":{"mid":7,"name":"作者"}}],"has_more":false}""")
                }
                else -> error("Unexpected endpoint: ${url.encodedPath}")
            }
        }) { repository ->
            val folder=repository.folders(false).items.single(); assertEquals(11,folder.type)
            val page=repository.folderVideos(folder,2)
            assertEquals("BV1NGZtBwELa",page.items.single().bvid); assertEquals(7L,page.items.single().owner.mid); assertFalse(page.more)
        }
    }

    @Test fun seasonOwnershipIsStillValidated() = runBlocking {
        fixture({ request ->
            assertEquals("/x/polymer/web-space/seasons_archives_list",request.requestUrl!!.encodedPath)
            JSONObject("""{"meta":{"season_id":100,"mid":99,"total":0},"page":{"total":0},"archives":[]}""")
        }) { repository ->
            try { repository.folderVideos(Folder(100,7,"合集",0,false,type=21),1); fail("An unrelated owner's season must be rejected") }
            catch (e: BiliFailure) { assertEquals("INVALID_RESPONSE",e.code) }
        }
    }

    @Test fun incompleteDirectoryIsAnErrorRatherThanAnEmptyCollection() = runBlocking {
        fixture({ JSONObject("""{"count":1,"list":null}""") }) { repository ->
            try { repository.folders(true); fail("A missing nonempty directory must remain an error") }
            catch (e: BiliFailure) { assertEquals("INVALID_RESPONSE",e.code) }
        }
    }

    @Test fun oneIncompleteCollectedEntryDoesNotHideTheRestOfTheDirectory() = runBlocking {
        fixture({ request ->
            assertEquals("/x/v3/fav/folder/collected/list",request.requestUrl!!.encodedPath)
            JSONObject("""{"count":21,"has_more":true,"list":[{"id":100,"mid":7,"title":"正常合集","media_count":5,"type":21},{"id":0,"mid":0,"title":"失效条目","type":21,"state":1},{"id":101,"mid":8,"title":"正常收藏夹","media_count":2,"type":11}]}""")
        }) { repository ->
            val page=repository.folders(true)
            assertEquals(listOf("正常合集","失效条目","正常收藏夹"),page.items.map { it.title })
            assertTrue(page.more); assertTrue(page.items[1].unavailable)
            assertNotNull(page.items[1].readError); assertNull(page.items[0].readError); assertNull(page.items[2].readError)
        }
    }

    @Test fun unreadableCollectedRowsStayVisibleAsErrorsWithoutInventingFolderIds() = runBlocking {
        fixture({ JSONObject("""{"count":2,"has_more":false,"list":[null,{"id":101,"mid":8,"title":"正常收藏夹","media_count":2}]}""") }) { repository ->
            val page=repository.folders(true)
            assertEquals(2,page.items.size); assertEquals(0L,page.items.first().id)
            assertNotNull(page.items.first().readError); assertTrue(page.items.first().unavailable)
            assertEquals(101L,page.items.last().id); assertFalse(page.more)
        }
    }

    @Test fun malformedOwnedFoldersStillFailStrictValidation() = runBlocking {
        fixture({ JSONObject("""{"count":1,"list":[{"id":0,"mid":42,"title":"不完整的自建收藏夹"}]}""") }) { repository ->
            try { repository.folders(false); fail("Owned folders must retain strict validation") }
            catch (e: BiliFailure) { assertEquals("INVALID_RESPONSE",e.code) }
        }
    }

    @Test fun upstreamDirectoryFailuresAreNeverConvertedToAnEmptyOrPartialSuccess() = runBlocking {
        fixture({ JSONObject() },errorCode=-352) { repository ->
            try { repository.folders(true); fail("Upstream failures must remain visible") }
            catch (e: BiliFailure) { assertEquals("-352",e.code) }
        }
    }
}

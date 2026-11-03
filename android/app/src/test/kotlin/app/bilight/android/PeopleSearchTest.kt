package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class PeopleSearchTest {
    private class MemoryStore: SecureStore {
        var value: ByteArray?=null
        override fun load()=value
        override fun save(bytes: ByteArray) { value=bytes }
        override fun clear() { value=null }
    }
    private fun romanize(name: String)=when(name.replace(" ","")) {
        "影视飓风" -> "ying shi ju feng"
        "超Carry的柴西" -> "chao carry de chai xi"
        "小鹿Lawrence" -> "xiao lu lawrence"
        "女流" -> "nǚ liú"
        else -> name
    }
    @Test fun includesLaterPagesAndIndexesNamesPinyinAndInitials() = runBlocking {
        val search=PeopleSearch(::romanize); val pages=mutableListOf<Int>(); val store=MemoryStore()
        val first=User(8,"影视飓风",null)
        search.refresh(42,store) { page ->
            pages+=page
            if (page==1) Page(listOf(first,User(9,"超Carry的柴西",null),User(11,"女流",null)),true)
            else Page(listOf(User(10,"小鹿Lawrence",null),first),false)
        }
        assertEquals(listOf(1,2),pages)
        listOf(" law " to 10L,"飓" to 8L,"ＣＡＲＲＹ" to 9L,"yingshijufeng" to 8L,"ying shi" to 8L,"ysjf" to 8L,"yjf" to 8L,"jufeng" to 8L,"nvliu" to 11L,"nuliu" to 11L,"xll" to 10L).forEach { (query,id) ->
            search.keyword=query; assertEquals("query=$query",listOf(id),search.matches().map { it.mid })
        }
        search.keyword="不存在"; assertTrue(search.matches().isEmpty())
        search.keyword=" "; assertTrue(search.matches().isEmpty())
        assertEquals(4,search.items!!.size); assertTrue(search.complete)
        assertEquals(2,pages.size)
    }
    @Test fun storedRosterIsSearchableBeforeAnyRefreshAndSurvivesRefreshFailure() = runBlocking {
        val store=MemoryStore(); val search=PeopleSearch(::romanize)
        search.refresh(42,store) { Page(listOf(User(8,"影视飓风",null)),false) }
        val snapshot=store.value!!.clone()
        val reopened=PeopleSearch(::romanize); reopened.restore(42,store)
        reopened.keyword="ysjf"; assertEquals(8L,reopened.matches().single().mid)
        assertTrue(reopened.complete)
        reopened.refresh(42,store) { page -> if (page==1) Page(listOf(User(9,"别的用户",null)),true) else error("读取失败") }
        assertEquals(listOf(8L),reopened.items!!.map { it.mid })
        assertArrayEquals(snapshot,store.value); assertNotNull(reopened.error); assertFalse(reopened.busy)
        reopened.refresh(42,store) { Page(emptyList(),false) }
        assertTrue(reopened.items!!.isEmpty()); assertNull(reopened.error)
    }
    @Test fun firstPageIsSearchableWhileTheRestLoadsAndPartialFailureIsExplicit() = runBlocking {
        val search=PeopleSearch(::romanize); val store=MemoryStore()
        val waiting=CompletableDeferred<Unit>(); val release=CompletableDeferred<Unit>()
        val loading=launch {
            search.refresh(42,store) { page ->
                if (page==1) Page(listOf(User(8,"影视飓风",null)),true)
                else { waiting.complete(Unit); release.await(); error("读取失败") }
            }
        }
        waiting.await(); search.keyword="ysjf"
        assertEquals(8L,search.matches().single().mid); assertFalse(search.complete); assertTrue(search.busy)
        release.complete(Unit); loading.join()
        assertNull(store.value); assertNotNull(search.error); assertFalse(search.complete)
    }
    @Test fun cacheCannotCrossAccountsAndCancellationCannotPublishTheOldRoster() = runBlocking {
        val store=MemoryStore(); store.value=PeopleSearch.encode(41,listOf(User(8,"影视飓风",null)))
        val search=PeopleSearch(::romanize); search.restore(42,store)
        assertNull(search.items)
        val entered=CompletableDeferred<Unit>(); val release=CompletableDeferred<Unit>()
        val reading=launch { search.refresh(42,store) { entered.complete(Unit); release.await(); Page(listOf(User(9,"用户",null)),false) } }
        entered.await(); reading.cancelAndJoin(); search.reset(); release.complete(Unit)
        assertNull(search.items); assertFalse(search.busy)
        assertEquals(41,org.json.JSONObject(String(store.value!!)).getInt("uid"))
    }
    @Test fun orphanCleanupOnlyTargetsOtherUidsPeopleSnapshots() {
        val files=listOf("people-42.enc","people-43.enc","people-43.enc.bak","people-44.enc.new","session.enc","downloads-43.enc","unrelated.enc","people-not-a-uid.enc")
        assertEquals(listOf("people-43","people-44"),SessionVault.peopleCacheNames(files,42))
        assertEquals(listOf("people-42","people-43","people-44"),SessionVault.peopleCacheNames(files,null))
    }
    @Test fun repeatedUpstreamPagesDoNotBecomeACompleteSnapshot() = runBlocking {
        val search=PeopleSearch(::romanize); val store=MemoryStore()
        search.refresh(42,store) { Page(listOf(User(8,"影视飓风",null)),true) }
        assertNull(store.value); assertNotNull(search.error); assertFalse(search.complete)
    }
}

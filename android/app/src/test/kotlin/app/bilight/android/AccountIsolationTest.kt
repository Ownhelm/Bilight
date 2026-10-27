package app.bilight.android

import app.bilight.android.core.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AccountIsolationTest {
    private class MemoryStore: SecureStore {
        var value: ByteArray? = null
        override fun load() = value
        override fun save(bytes: ByteArray) { value=bytes }
        override fun clear() { value=null }
    }
    private fun client(server: MockWebServer) = OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
        val original=chain.request()
        val url=server.url(original.url.encodedPath).newBuilder().encodedQuery(original.url.encodedQuery).build()
        chain.proceed(original.newBuilder().url(url).build()).newBuilder().request(original).build()
    }.build()
    private fun nav(mid: Int) = MockResponse().setBody("""{"code":0,"data":{"isLogin":true,"mid":$mid,"uname":"隔离测试","face":""}}""")
    @Test fun encryptedStoreContractRestoresOnlyThisAppsOwnIssuedSessionAndClearsOnLogout() = runBlocking {
        val server=MockWebServer(); server.start(); val store=MemoryStore()
        try {
            server.enqueue(nav(42)); val first=BiliHttp(store,client(server))
            first.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only; unrelated=must-not-be-kept")
            val saved=JSONObject(String(store.value!!)); assertEquals(42L,saved.obj("user").optLong("mid"))
            assertFalse(String(store.value!!).contains("unrelated"))
            server.enqueue(nav(42)); val second=BiliHttp(store,client(server)); assertEquals(42L,second.restore()?.mid)
            assertEquals(42L,second.ensureAccount())
            val old=second.generation; second.logout(); assertNull(store.value); assertNull(second.user)
            try { second.check(old); fail() } catch (e: BiliFailure) { assertEquals("ACCOUNT_CHANGED",e.code) }
        } finally { server.shutdown() }
    }
    @Test fun offlineRestoreKeepsValidatedProfileForExistingDownloadsButCannotPerformCloudWrites() = runBlocking {
        val server=MockWebServer(); server.start(); val store=MemoryStore()
        try {
            server.enqueue(nav(42)); BiliHttp(store,client(server)).acceptLogin("SESSDATA=fixture-only; bili_jct=test-only")
            val offline=OkHttpClient.Builder().addInterceptor { throw java.net.UnknownHostException("fixture") }.build()
            val restored=BiliHttp(store,offline); assertEquals(42L,restored.restore()?.mid)
            try { restored.ensureAccount(); fail() } catch (e: BiliFailure) { assertEquals("NETWORK",e.code) }
        } finally { server.shutdown() }
    }
    @Test fun realSessionExpiryDoesNotMasqueradeAsAConnectedAccount() = runBlocking {
        val server=MockWebServer(); server.start(); val store=MemoryStore()
        try {
            server.enqueue(nav(42)); BiliHttp(store,client(server)).acceptLogin("SESSDATA=fixture-only; bili_jct=test-only")
            server.enqueue(MockResponse().setBody("""{"code":-101,"message":"not logged in"}"""))
            val restored=BiliHttp(store,client(server)); assertNull(restored.restore())
            server.enqueue(MockResponse().setBody("""{"code":-101,"message":"not logged in"}"""))
            try { restored.ensureAccount(); fail() } catch (e: BiliFailure) { assertEquals("-101",e.code) }
            assertNull(store.value)
        } finally { server.shutdown() }
    }
    @Test fun logoutDuringAnInFlightLoginCannotRestoreThePreviousAccountsCookies() = runBlocking {
        val server=MockWebServer(); server.start(); val store=MemoryStore()
        try {
            server.enqueue(nav(42)); val http=BiliHttp(store,client(server)); http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only")
            server.takeRequest()
            server.enqueue(nav(43).setHeadersDelay(2,java.util.concurrent.TimeUnit.SECONDS))
            val attempt=async(Dispatchers.Default) { runCatching { http.acceptLogin("SESSDATA=another-fixture; bili_jct=another-test") } }
            assertNotNull(server.takeRequest(2,java.util.concurrent.TimeUnit.SECONDS))
            http.logout(); attempt.await()
            assertNull(http.user); assertNull(store.value)
            try { http.csrf(); fail() } catch (e: BiliFailure) { assertEquals("-101",e.code) }
        } finally { server.shutdown() }
    }
    @Test fun officiallyRotatedCookiesAreSavedBeforeTheNextAppLaunch() = runBlocking {
        val server=MockWebServer(); server.start(); val store=MemoryStore()
        try {
            val http=BiliHttp(store,client(server)); server.enqueue(nav(42)); http.acceptLogin("SESSDATA=fixture-only; bili_jct=test-only")
            server.enqueue(MockResponse().setHeader("Set-Cookie","sid=rotated-fixture; Domain=.bilibili.com; Path=/; Secure; Max-Age=3600").setBody("""{"code":0,"data":{}}"""))
            http.request("/x/fixture")
            assertTrue(String(store.value!!).contains("sid=rotated-fixture"))
            server.enqueue(nav(42)); val restored=BiliHttp(store,client(server)); assertEquals(42L,restored.restore()?.mid)
            server.takeRequest(); server.takeRequest()
            assertTrue(server.takeRequest().getHeader("Cookie")!!.contains("sid=rotated-fixture"))
        } finally { server.shutdown() }
    }
    @Test fun delayedStartupRestoreCannotOverwriteANewerSuccessfulLogin() = runBlocking {
        val entered=java.util.concurrent.CountDownLatch(1); val release=java.util.concurrent.CountDownLatch(1)
        val store=object: SecureStore {
            var bytes: ByteArray?=null; var delayed=false
            override fun load(): ByteArray? { val snapshot=bytes?.clone(); if (delayed) { entered.countDown(); check(release.await(5,java.util.concurrent.TimeUnit.SECONDS)) }; return snapshot }
            override fun save(bytes: ByteArray) { this.bytes=bytes }
            override fun clear() { bytes=null }
        }
        val server=MockWebServer(); server.start()
        try {
            server.enqueue(nav(42)); BiliHttp(store,client(server)).acceptLogin("SESSDATA=old-fixture; bili_jct=old-test")
            store.delayed=true
            val http=BiliHttp(store,client(server))
            val restoring=async(Dispatchers.Default) { runCatching { http.restore() } }
            assertTrue(entered.await(2,java.util.concurrent.TimeUnit.SECONDS))
            server.enqueue(nav(43)); assertEquals(43L,http.acceptLogin("SESSDATA=new-fixture; bili_jct=new-test").mid)
            server.enqueue(nav(42)); release.countDown()
            val error=restoring.await().exceptionOrNull()
            assertTrue("Old restore must be discarded after a newer login",error is BiliFailure && error.code=="ACCOUNT_CHANGED")
            assertEquals(43L,http.user?.mid); assertEquals(43L,JSONObject(String(store.bytes!!)).obj("user").optLong("mid"))
        } finally { release.countDown(); server.shutdown() }
    }
}

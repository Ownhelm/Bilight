package app.bilight.android

import android.os.StrictMode
import app.bilight.android.ui.QRLoginSession
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test

class QRLoginCleanupTest {
    @Test fun cancelledLoginClosesItsTlsConnectionAwayFromTheUiThread() = runBlocking {
        val server=MockWebServer()
        val certificate=HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val tls=HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        server.useHttps(tls.sslSocketFactory(),false); server.start()
        val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager)
            .addInterceptor { chain -> chain.proceed(chain.request().newBuilder().url(server.url("/qr")).build()) }.build()
        val session=QRLoginSession(client)
        try {
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"code":86101}}"""))
            assertEquals(86101,session.request("generate").first.getInt("code"))
            assertEquals(1,client.connectionPool.idleConnectionCount())
            val started=CompletableDeferred<Unit>()
            val job=launch(Dispatchers.Main) {
                val policy=StrictMode.getThreadPolicy()
                StrictMode.setThreadPolicy(StrictMode.ThreadPolicy.Builder(policy).detectNetwork().penaltyDeathOnNetwork().build())
                try { started.complete(Unit); awaitCancellation() }
                finally { try { session.close() } finally { StrictMode.setThreadPolicy(policy) } }
            }
            started.await(); job.cancelAndJoin()
            assertEquals("Cancelled login retained an idle TLS connection",0,client.connectionPool.connectionCount())
        } finally { withContext(NonCancellable+Dispatchers.IO) { session.close(); server.shutdown() } }
    }
}

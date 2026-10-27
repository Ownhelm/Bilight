package app.bilight.android

import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.bilight.android.core.AppModel
import app.bilight.android.core.Route
import app.bilight.android.core.User
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class StartupRestoreTest {
    @Test fun startupRestoreDoesNotDiscardPublicNavigationOpenedWhileItWasLoading() {
        val app=ApplicationProvider.getApplicationContext<BilightApplication>()
        assumeTrue("Run only in the isolated anonymous emulator",app.http.user==null)
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val store=ViewModelStore()
        lateinit var model: AppModel
        val route=Route.Creator(User(42,"启动恢复测试",null))
        try {
            instrumentation.runOnMainSync {
                model=ViewModelProvider(store,ViewModelProvider.AndroidViewModelFactory(app))[AppModel::class.java]
                model.keyword="startup-restore-regression"; model.open(route)
            }
            val deadline=android.os.SystemClock.elapsedRealtime()+5000
            var restored=false
            while (!restored && android.os.SystemClock.elapsedRealtime()<deadline) {
                instrumentation.runOnMainSync { restored=!model.restoring }
                if (!restored) Thread.sleep(25)
            }
            assertTrue("Startup restoration did not finish",restored)
            instrumentation.runOnMainSync {
                assertEquals("Session restore reset the current page to search",listOf(route),model.routes.toList())
                assertEquals("startup-restore-regression",model.keyword)
            }
        } finally { instrumentation.runOnMainSync { store.clear() } }
    }
}

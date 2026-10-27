package app.bilight.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.activity.viewModels
import app.bilight.android.core.AppModel
import app.bilight.android.ui.MainApp

class MainActivity : ComponentActivity() {
  private val app: AppModel by viewModels()
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    // The app uses white pages even when the system is dark; keep system icons readable.
    val bars=SystemBarStyle.light(android.graphics.Color.TRANSPARENT,android.graphics.Color.TRANSPARENT)
    enableEdgeToEdge(statusBarStyle=bars,navigationBarStyle=bars)
    setContent {
      MainApp(app)
    }
  }
  override fun onStart() { super.onStart(); app.retryHistory() }
}

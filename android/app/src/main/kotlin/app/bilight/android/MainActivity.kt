package app.bilight.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.activity.viewModels
import androidx.compose.runtime.LaunchedEffect
import app.bilight.android.core.AppModel
import app.bilight.android.ui.MainApp

class MainActivity : ComponentActivity() {
  private val app: AppModel by viewModels()
  private var darkBars: Boolean? = null
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    updateSystemBars(app.darkAppearance)
    setContent {
      val dark = app.darkAppearance
      LaunchedEffect(dark) { updateSystemBars(dark) }
      MainApp(app)
    }
  }
  private fun updateSystemBars(dark: Boolean) {
    if (darkBars == dark) return
    darkBars = dark
    val transparent = android.graphics.Color.TRANSPARENT
    val bars = if (dark) SystemBarStyle.dark(transparent) else SystemBarStyle.light(transparent, transparent)
    enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
  }
  override fun onStart() { super.onStart(); app.retryHistory() }
}

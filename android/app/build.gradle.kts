plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.compose.compiler)
}

android {
  namespace = "app.bilight.android"
  compileSdk = 36
  defaultConfig {
    applicationId = "app.bilight.android"
    minSdk = 26
    targetSdk = 36
    versionCode = 5
    versionName = "0.1.3"
    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
  }

  buildTypes {
    release {
      isMinifyEnabled = false
      proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
    }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  buildFeatures {
    compose = true
    aidl = false
    buildConfig = true
    shaders = false
  }

  packaging {
    resources {
      excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
  }
}

kotlin {
  jvmToolchain(17)
}

dependencies {
  val composeBom = platform(libs.androidx.compose.bom)
  implementation(composeBom)
  androidTestImplementation(composeBom)

  // Core Android dependencies
  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.lifecycle.runtime.ktx)
  implementation(libs.androidx.activity.compose)

  // Arch Components
  implementation(libs.androidx.lifecycle.runtime.compose)
  implementation(libs.androidx.lifecycle.viewmodel.compose)

  // Compose
  implementation(libs.androidx.compose.ui)
  implementation(libs.androidx.compose.ui.tooling.preview)
  implementation(libs.androidx.compose.material3)
  // Tooling
  debugImplementation(libs.androidx.compose.ui.tooling)
  // Instrumented tests
  androidTestImplementation(libs.androidx.compose.ui.test.junit4)
  debugImplementation(libs.androidx.compose.ui.test.manifest)

  // Local tests: jUnit, coroutines, Android runner
  testImplementation(libs.junit)
  testImplementation(libs.kotlinx.coroutines.test)

  // Instrumented tests: jUnit rules and runners
  androidTestImplementation(libs.androidx.test.core)
  androidTestImplementation(libs.androidx.test.ext.junit)
  androidTestImplementation(libs.androidx.test.runner)
  androidTestImplementation(libs.androidx.test.espresso.core)

  implementation("com.squareup.okhttp3:okhttp:4.12.0")
  implementation("com.google.zxing:core:3.5.3")
  implementation("io.coil-kt.coil3:coil-compose:3.3.0")
  implementation("io.coil-kt.coil3:coil-network-okhttp:3.3.0")
  implementation("androidx.media3:media3-exoplayer:1.8.0")
  implementation("androidx.media3:media3-exoplayer-dash:1.8.0")
  implementation("androidx.media3:media3-datasource-okhttp:1.8.0")
  implementation("androidx.media3:media3-ui:1.8.0")
  implementation("androidx.compose.material:material-icons-extended:1.7.8")
  testImplementation("org.json:json:20250517")
  testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
  androidTestImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
  androidTestImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
}

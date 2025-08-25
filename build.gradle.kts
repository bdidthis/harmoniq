plugins {
    id("com.android.application") version "8.3.2"
    id("org.jetbrains.kotlin.android") version "1.9.23"
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.harmoniq_clean_run"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.example.harmoniq_clean_run"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildTypes { release { signingConfig = signingConfigs.getByName("debug") } }
}
flutter { source = "../.." }
dependencies { }

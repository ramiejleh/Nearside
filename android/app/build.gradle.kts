plugins {
    id("com.android.application")
}

android {
    namespace = "dev.nearside"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.nearside"
        minSdk = 30 // Wireless debugging exists from Android 11.
        targetSdk = 36
        versionCode = 1
        versionName = "0.0.1-poc"
    }

    buildTypes {
        // The helper is launched by class name through app_process, so it must never be
        // renamed or stripped. The PoC only ships debug builds; keep minify off everywhere.
        release { isMinifyEnabled = false }
    }

    buildFeatures {
        aidl = true // the app <-> helper Binder interfaces in src/main/aidl
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

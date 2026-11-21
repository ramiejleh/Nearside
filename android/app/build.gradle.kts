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

    // Release key, given only by mac/scripts/release.sh (never stored in the repo). Without it,
    // release builds are unsigned; debug builds always use the usual debug key.
    val releaseKeystore = System.getenv("NEARSIDE_KEYSTORE")
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("NEARSIDE_KEYSTORE_PASS")
                keyAlias = System.getenv("NEARSIDE_KEY_ALIAS") ?: "nearside"
                keyPassword = System.getenv("NEARSIDE_KEY_PASS") ?: System.getenv("NEARSIDE_KEYSTORE_PASS")
            }
        }
    }

    buildTypes {
        // The helper is launched by class name through app_process, so it must never be
        // renamed or stripped. Keep minify off everywhere.
        release {
            isMinifyEnabled = false
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    lint {
        // The helper runs as the shell user, where hidden APIs are reachable on purpose
        // (scrcpy-style reflection); release builds would otherwise fail on it.
        disable += "BlockedPrivateApi"
    }

    buildFeatures {
        aidl = true // the app <-> helper Binder interfaces in src/main/aidl
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

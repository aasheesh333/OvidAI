import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

// Release signing config — read from CI-injected properties (keystore.properties
// generated from GitHub secrets) or fall back to debug for local `flutter run`.
val keystorePropsFile = rootProject.file("keystore.properties")
val hasReleaseKeys = keystorePropsFile.exists()
val keystoreProps = Properties().apply {
    if (hasReleaseKeys) keystorePropsFile.inputStream().use { load(it) }
}

android {
    namespace = "com.dhanuk.ovidai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dhanuk.ovidai"
        // Android 6.0+ (API 23) — Flutter's default is 24; set explicitly
        // so 6.x devices can install. The app shell (chat/providers/
        // browser) runs on 23; the native sandbox additionally needs
        // Android 7+ (API 24) — checked at runtime with a friendly
        // "continue without sandbox" fallback (sandbox_service preflight).
        minSdk = 23
        // The native sandbox execs bash/python/node from the app's files
        // dir (Termux-style $PREFIX). Android 10+ blocks execve() AND
        // exec-mmap of anything under /data/user/<u>/<pkg> for apps
        // targeting API 29+ (SELinux neverallow on app_data_file) — the
        // sandbox dies with EACCES no matter the ABI or file mode.
        // Targeting 28 keeps the legacy exec allowance on Android 7–16
        // (Termux ships targetSdk 28 for the same reason, which is why
        // it cannot update on the Play Store). DO NOT bump this without
        // moving every exec'd binary and dlopen'd lib into packaged
        // jniLibs (nativeLibraryDir is the only exec-allowed path for
        // targetSdk 29+).
        targetSdk = 28

        lint {
            // targetSdk 28 is deliberate (see the comment above — Play's
            // targetSdk floor is incompatible with app-data exec). This
            // build is sideloaded, so the Play-policy lint that would
            // fail lintVitalRelease on targetSdk < 33 does not apply.
            disable += "ExpiredTargetSdkVersion"
        }
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeys) {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig =
                if (hasReleaseKeys) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
        }
    }

    firebaseCrashlytics {
        // The bundled libovid_bootstrap.so payloads are zip archives (not
        // real ELF libs) — crashlytics symbol/mapping uploads 400 on them
        // and break the CI build. Symbols aren't useful here anyway
        // (Dart AOT obfuscates).
        nativeSymbolUploadEnabled = false
        mappingFileUploadEnabled = false
    }
}

// Belt-and-suspenders: if the extension flags above are ignored, kill the
// tasks outright. The 43MB zip-in-.so payloads have no debug symbols to
// upload and mapping is meaningless for Dart AOT builds.
tasks.matching { it.name.startsWith("uploadCrashlytics") }.configureEach {
    enabled = false
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

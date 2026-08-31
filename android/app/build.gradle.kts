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
        // Android 6.0+ (API 23) — Flutter default is 24; we support one
        // version lower for broad device coverage.  The phone terminal
        // tier works everywhere; the proot sandbox additionally requires
        // an arm64 device (checked at runtime with a friendly fallback).
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
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
}

firebaseCrashlytics {
    // The bundled libovid_bootstrap.so payloads are zip archives (not real
    // ELF libs) — crashlytics symbol/mapping uploads 400 on them and break
    // the CI build. Symbols aren't useful here anyway (Dart AOT obfuscates).
    nativeSymbolUploadEnabled = false
    mappingFileUploadEnabled = false
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

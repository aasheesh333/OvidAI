import java.util.Properties
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.util.Base64

// Google Play automatic protection requires API 24+; 23 uploads are rejected.
val ovidMinSdk = 24

// Google Play distribution switch. The single source of truth is the Dart
// define `--dart-define=OVID_PLAY_BUILD=true` (Flutter forwards dart-defines
// to Gradle as the base64, comma-separated `dart-defines` property), so the
// Dart feature gates (lib/core/distribution.dart) and the native packaging
// below can never disagree. `-Povid.play=true` exists for Gradle-only tasks.
// A Play build merges src/play/AndroidManifest.xml, which removes every
// permission without a Play-approvable core use. Every build (Play and
// sideload) targets API 36 and ships no on-device Linux userland (removed in
// P8 Task 13). Control mode and the on-device sandbox are absent from every
// channel (spec D5).
val ovidPlayBuild: Boolean = run {
    val defines = (project.findProperty("dart-defines") as String?).orEmpty()
        .split(",").filter { it.isNotBlank() }
        .map { runCatching { String(Base64.getDecoder().decode(it)) }.getOrDefault("") }
    defines.any { it.trim() == "OVID_PLAY_BUILD=true" } ||
        project.findProperty("ovid.play")?.toString() == "true"
}
// One target for every channel: API 36 (Play's floor for new apps/updates
// since 2026-08-31). The old sideload target 28 existed only so the removed
// on-device sandbox could exec binaries from app data (blocked for API 29+).
val ovidTargetSdk = 36

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

// Debug remains usable without release credentials. Parse errors are deferred
// until a release task is selected, never converted into debug signing.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties()
val keystoreReadError = runCatching {
    if (keystorePropsFile.isFile) keystorePropsFile.inputStream().use { keystoreProps.load(it) }
}.exceptionOrNull()

fun validateProductionSigning() {
    fun refuse(reason: String): Nothing = throw GradleException("Production release refused: $reason")
    if (!keystorePropsFile.isFile || keystoreReadError != null) {
        refuse("provide a readable android/keystore.properties; debug signing is never a release fallback")
    }
    val required = listOf("storeFile", "storePassword", "keyAlias", "keyPassword", "certSha256")
    if (required.any { keystoreProps.getProperty(it).isNullOrBlank() }) {
        refuse("keystore.properties requires storeFile, storePassword, keyAlias, keyPassword and certSha256")
    }
    val store = rootProject.file(keystoreProps.getProperty("storeFile"))
    if (!store.isFile) refuse("configured release keystore is missing")
    // Do not propagate provider exception messages: they may contain private paths/aliases.
    val valid = runCatching {
        val keyStore = KeyStore.getInstance(store, keystoreProps.getProperty("storePassword").toCharArray())
        val alias = keystoreProps.getProperty("keyAlias")
        val key = keyStore.getKey(alias, keystoreProps.getProperty("keyPassword").toCharArray()) as PrivateKey
        val cert = keyStore.getCertificate(alias) as X509Certificate
        cert.checkValidity()
        require(!cert.subjectX500Principal.name.contains("CN=Android Debug", ignoreCase = true))
        require(!alias.equals("androiddebugkey", ignoreCase = true))
        val actual = MessageDigest.getInstance("SHA-256").digest(cert.encoded)
            .joinToString("") { "%02x".format(it) }
        val expected = keystoreProps.getProperty("certSha256").replace(":", "").lowercase()
        require(expected.matches(Regex("[0-9a-f]{64}")) && actual == expected)
        val algorithm = when (key.algorithm) {
            "RSA" -> "SHA256withRSA"
            "EC" -> "SHA256withECDSA"
            "DSA" -> "SHA256withDSA"
            else -> error("unsupported key algorithm")
        }
        val challenge = "Ovid release signing validation".toByteArray()
        val proof = Signature.getInstance(algorithm).run {
            initSign(key); update(challenge); sign()
        }
        require(Signature.getInstance(algorithm).run {
            initVerify(cert); update(challenge); verify(proof)
        })
    }.isSuccess
    if (!valid) refuse("invalid, expired, debug, or mismatched signing identity; check keystore credentials and certSha256")
}

// Resolve the actual graph (including abbreviated/aggregate task requests), then
// refuse before compilation. This project does not enable configuration caching.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name.contains("Release") }) {
        validateProductionSigning()
    }
}
tasks.register("validateProductionReleaseSigning") {
    group = "verification"
    description = "Validate the production private key and pinned certificate before building."
    doLast { validateProductionSigning() }
}

android {
    namespace = "com.dhanuk.ovidai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dhanuk.ovidai"
        // Android 6.0 remains supported by the app shell.
        minSdk = ovidMinSdk
        // Execution is server-side (cloud thin client); nothing execs from
        // app data any more, so sideload and Play builds share API 36.
        targetSdk = ovidTargetSdk
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Share/Collab App Links host (/s/...). Must match the app's
        // OVID_PUBLIC_SHARE_ORIGIN and serve /.well-known/assetlinks.json.
        manifestPlaceholders["ovidShareHost"] =
            (project.findProperty("ovidShareHost") as String?) ?: "ovidsi.com"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        create("release") {
            if (keystoreReadError == null) {
                storeFile = keystoreProps.getProperty("storeFile")?.takeIf { it.isNotBlank() }?.let { rootProject.file(it) }
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
            signingConfig = signingConfigs.getByName("release")
        }
    }

    firebaseCrashlytics {
        // Uploads stay off: CI archives the R8 mapping (plugin Java/Kotlin is
        // obfuscated with -repackageclasses) and the Dart split-debug-info
        // symbols as private workflow artifacts instead (CT-021).
        nativeSymbolUploadEnabled = false
        mappingFileUploadEnabled = false
    }
}

// Belt-and-suspenders: if the extension flags above are ignored, kill the
// tasks outright. Symbolication uses the CI artifacts (see above).
tasks.matching { it.name.startsWith("uploadCrashlytics") }.configureEach {
    enabled = false
}

// Secret-free development builds deliberately have no Firebase resource config.
// Production keeps Google's normal validation; never synthesize configuration.
tasks.matching { it.name == "processDebugGoogleServices" }.configureEach {
    onlyIf("a real Firebase configuration is available for debug") {
        listOf("google-services.json", "src/debug/google-services.json", "src/google-services.json")
            .any { file(it).isFile }
    }
}

// Resource-backed host tests consume Flutter's merged assets under AGP 9.
tasks.matching { it.name == "packageDebugUnitTestForUnitTest" }.configureEach {
    dependsOn("copyFlutterAssetsDebug")
}

// Play overlay manifest: removes the AccessibilityService, the idle
// specialUse foreground-service type and permissions Play would reject.
androidComponents {
    onVariants { variant ->
        if (ovidPlayBuild) variant.sources.manifests.addStaticManifestFile("src/play/AndroidManifest.xml")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 16 KB page size: androidx.datastore 1.1.x (pulled in by
    // shared_preferences_android 2.4.16 at 1.1.7) ships
    // libdatastore_shared_counter.so with a GNU_RELRO end that is not 16 KB
    // aligned. 1.2.0 still has it; 1.2.1 is the first release with 16 KB clean
    // arm64-v8a/armeabi-v7a/x86/x86_64 libraries. minSdk 24 is at or below ours.
    constraints {
        for (artifact in listOf(
            "datastore", "datastore-core", "datastore-core-android", "datastore-core-okio",
            "datastore-preferences", "datastore-preferences-android",
            "datastore-preferences-core", "datastore-preferences-core-jvm",
        )) {
            implementation("androidx.datastore:$artifact:1.2.1") {
                because("first androidx.datastore with 16 KB aligned native libraries")
            }
        }
    }
    implementation("com.android.installreferrer:installreferrer:2.2")
    // Ovid ships on Google Play only. RevenueCat's hybrid-common pulls the
    // Amazon Appstore store as a sibling module; it merges an Amazon IAP
    // receiver and permission into our manifest, and that SDK's bytecode has
    // no stackmap frames, so every Robolectric host test dies with
    // java.lang.VerifyError while the merged manifest is parsed. Excluding it
    // keeps the Google store (com.revenuecat.purchases:purchases) intact.
    configurations.configureEach {
        exclude(group = "com.revenuecat.purchases", module = "purchases-store-amazon")
    }
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    testImplementation("org.robolectric:robolectric:4.14.1")
    // Desktop-mode client hints: WebSettingsCompat.setUserAgentMetadata and
    // WebViewCompat.addDocumentStartJavaScript live here. webview_flutter_android
    // depends on webkit with `implementation`, so it is NOT on this module's
    // compile classpath — declare it explicitly. Version matches the
    // webview_flutter_android pin so the resolved graph stays single-version.
    implementation("androidx.webkit:webkit:1.12.0")
}

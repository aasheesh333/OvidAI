import java.util.Properties
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate

val ovidMinSdk = 23

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

    packaging {
        jniLibs {
            // libovid_bootstrap.so is NOT an ELF library — it is a zip archive
            // of the Termux payload shipped with an .so name so Android
            // packages it into jniLibs. This does not make extracted app-data
            // code executable at targetSdk 29+. llvm-strip cannot parse
            // it ("not recognized as a valid object file") and its retry loop
            // ballooned the build dir until the runner hit "No space left on
            // device". Keep its debug symbols so AGP skips the strip step.
            keepDebugSymbols += "**/libovid_bootstrap.so"
        }
    }

    defaultConfig {
        applicationId = "com.dhanuk.ovidai"
        // Android 6.0 remains supported by the app shell.
        minSdk = ovidMinSdk
        // The native sandbox execs bash/python/node from the app's files
        // dir (Termux-style $PREFIX). Android 10+ blocks execve() AND
        // exec-mmap of anything under /data/user/<u>/<pkg> for apps
        // targeting API 29+ (SELinux neverallow on app_data_file) — the
        // sandbox dies with EACCES no matter the ABI or file mode.
        // Keep the legacy target until the immutable packaged-code architecture
        // is implemented and measured from the app process. A target-only bump
        // cannot qualify runtime behavior, downloaded code, or distribution.
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.android.installreferrer:installreferrer:2.2")
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

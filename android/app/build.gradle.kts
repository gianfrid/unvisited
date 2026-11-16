import java.io.File
import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Build date shown in the app: the latest commit's time (same source as the
// desktop's runtime git probe). An APK cannot read git at runtime, so gradle
// bakes it into BuildConfig here - no extra flags needed on flutter build.
// Empty outside a checkout; the app then falls back to "dev".
fun gitCommitTime(): String = try {
    val proc = ProcessBuilder("git", "log", "-1", "--format=%cI")
        .directory(projectDir)
        .start()
    val text = proc.inputStream.bufferedReader().use { it.readText() }.trim()
    proc.waitFor()
    if (proc.exitValue() == 0 && text.isNotEmpty()) text else ""
} catch (e: Exception) {
    ""
}

android {
    namespace = "io.github.gianfrid.unvisited"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.gianfrid.unvisited"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "BUILD_TIME", "\"${gitCommitTime()}\"")
    }

    // Release signing comes from the environment so CI can sign with repo
    // secrets while local builds keep the debug keys. Nothing secret is
    // ever committed; the keystore itself is a base64 env var.
    val keystoreB64 = System.getenv("UNVISITED_KEYSTORE_B64")
    signingConfigs {
        if (keystoreB64 != null) {
            create("release") {
                val keystoreFile = File.createTempFile("unvisited-release", ".jks")
                keystoreFile.writeBytes(Base64.getDecoder().decode(keystoreB64))
                keystoreFile.deleteOnExit()
                storeFile = keystoreFile
                storePassword = System.getenv("UNVISITED_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("UNVISITED_KEY_ALIAS")
                keyPassword = System.getenv("UNVISITED_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreB64 != null) {
                signingConfigs.getByName("release")
            } else {
                // Debug keys locally, so `flutter run --release` works.
                signingConfigs.getByName("debug")
            }
        }
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

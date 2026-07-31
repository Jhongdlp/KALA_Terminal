import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config is read from android/key.properties (gitignored).
// Without it (e.g. a fresh clone) the build falls back to the debug key so
// `flutter run` still works. Distributed APKs must always be signed with the
// SAME keystore across releases so the in-app updater can install updates over
// the installed app. Current releases are signed with android/app/debug.keystore
// (the key the published KALA builds already use — SHA-1 81:F2:49:94…).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.antigravity.terminalagent.terminal_agent"
    // Pinned to 36 (not flutter.compileSdkVersion) because updated plugins
    // (file_picker → flutter_plugin_android_lifecycle) require compiling against
    // API 36+. This only affects which APIs are available at compile time;
    // runtime behavior stays governed by targetSdk (28, see defaultConfig).
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Unchanged from KALA so this SSH-only build updates the installed app
        // in place (same signing key required — see android/key.properties).
        applicationId = "com.antigravity.terminalagent.terminal_agent"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Pinned to 28 on purpose. With targetSdk 28 the legacy
        // READ/WRITE_EXTERNAL_STORAGE permissions still grant full access to
        // /storage/emulated/0 (pre-scoped-storage), which the "adjuntar" picker
        // and the SFTP → Download/KAMMEL downloader rely on. At API 29+ scoped
        // storage would break those without MANAGE_EXTERNAL_STORAGE. Play Store
        // upload needs >=34, but this app is sideloaded via `flutter run`/`build apk`.
        targetSdk = 28
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the real release key when key.properties is present
            // (the distributed APKs); fall back to debug so a fresh clone can
            // still `flutter run --release` without the keystore.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }

    lint {
        // targetSdk is intentionally pinned to 28 (see defaultConfig) for legacy
        // shared-storage access. Play Store's lint flags that as a fatal error in
        // release builds; this app is sideloaded, not published, so silence just
        // that check instead of raising targetSdk.
        disable += "ExpiredTargetSdkVersion"
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

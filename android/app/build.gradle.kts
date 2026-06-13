import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config is read from android/key.properties (gitignored).
// Without it (e.g. a fresh clone) the build falls back to the debug key so
// `flutter run` still works, but distributed APKs MUST be signed with the real
// release key so the in-app updater's signature check keeps holding.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.antigravity.terminalagent.terminal_agent"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.antigravity.terminalagent.terminal_agent"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Pinned to 28 on purpose. Android assigns the app's SELinux domain from
        // targetSdkVersion; at API 29+ the app lands in the stricter
        // `untrusted_app_29+` domain that blocks fork/exec of child binaries,
        // which kills the local PTY shell (every command -> "Permission denied").
        // Termux pins to 28 for the same reason. Keep this until the terminal is
        // reworked to exec from nativeLibraryDir. Play Store upload needs >=34,
        // but this app is sideloaded via `flutter run`/`build apk`.
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
        // targetSdk is intentionally pinned to 28 (see defaultConfig) so the local
        // PTY terminal keeps working. Play Store's lint flags that as a fatal error
        // in release builds; this app is sideloaded, not published, so silence just
        // that check instead of raising targetSdk and breaking the terminal.
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

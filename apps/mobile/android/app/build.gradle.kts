import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/*
 * The environment is chosen once, by the define file (ADR-0015):
 *
 *   flutter build appbundle --release --dart-define-from-file=config/env/prod.json
 *
 * Flutter hands those values to Gradle base64-encoded in the `dart-defines` property, so the
 * application id suffix, the launcher label and the App Links host come from the same file the
 * Dart code reads and cannot disagree with it. dev and staging install beside prod.
 */
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.filter { it.isNotBlank() }
        ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
        ?.mapNotNull { entry ->
            val eq = entry.indexOf('=')
            if (eq <= 0) null else entry.substring(0, eq) to entry.substring(eq + 1)
        }
        ?.toMap()
        ?: emptyMap()

fun define(name: String, fallback: String): String =
    dartDefines[name]?.takeIf { it.isNotEmpty() } ?: fallback

val appFlavor = define("APP_FLAVOR", "dev")

/*
 * Release signing (RB-15). key.properties is gitignored and written by the release workflow
 * from repository secrets; the keystore itself never enters the repository. Without it a
 * release build is signed with the debug key: installable for testing, refused by Play.
 */
val keystoreProperties =
    Properties().apply {
        val file = rootProject.file("key.properties")
        if (file.exists()) FileInputStream(file).use { load(it) }
    }
val hasUploadKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.suskiierrands.app"
    // Pinned rather than inherited from the Flutter SDK: Play requires API 36 for new apps
    // and updates from 31 Aug 2026 [V] developer.android.com/google/play/requirements/target-sdk
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // One id on both stores (iOS: PRODUCT_BUNDLE_IDENTIFIER). Permanent once uploaded.
        applicationId = "com.suskiierrands.app"
        if (appFlavor != "prod") applicationIdSuffix = ".$appFlavor"
        minSdk = 24
        targetSdk = 36
        // From pubspec.yaml `version: x.y.z+build`; the release workflow overrides the build
        // number with --build-number so every upload is unique.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        manifestPlaceholders["appName"] = define("APP_NAME", "Suskii Errands")
        manifestPlaceholders["appLinkHost"] = define("APP_LINK_HOST", "suskii-errands.example")
        // Cleartext to the emulator's host loopback exists only for local Supabase in dev.
        manifestPlaceholders["networkSecurityConfig"] =
            if (appFlavor == "dev") "@xml/network_security_config_dev" else "@xml/network_security_config"
    }

    signingConfigs {
        create("upload") {
            if (hasUploadKey) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasUploadKey) signingConfigs.getByName("upload") else signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

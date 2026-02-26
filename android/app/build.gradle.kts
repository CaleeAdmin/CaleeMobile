import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val envStoreFile = providers.environmentVariable("ANDROID_KEYSTORE_PATH").orNull
val envStorePassword = providers.environmentVariable("ANDROID_KEYSTORE_PASSWORD").orNull
val envKeyAlias = providers.environmentVariable("ANDROID_KEY_ALIAS").orNull
val envKeyPassword = providers.environmentVariable("ANDROID_KEY_PASSWORD").orNull

val releaseStoreFilePath = keystoreProperties["storeFile"]?.toString() ?: envStoreFile
val releaseStorePassword = keystoreProperties["storePassword"]?.toString() ?: envStorePassword
val releaseKeyAlias = keystoreProperties["keyAlias"]?.toString() ?: envKeyAlias
val releaseKeyPassword = keystoreProperties["keyPassword"]?.toString() ?: envKeyPassword

val releaseKeystoreFile = releaseStoreFilePath?.let { file(it) }
val hasReleaseSigningConfig =
    releaseKeystoreFile?.exists() == true &&
        !releaseStorePassword.isNullOrBlank() &&
        !releaseKeyAlias.isNullOrBlank() &&
        !releaseKeyPassword.isNullOrBlank()

if (!hasReleaseSigningConfig) {
    logger.warn(
        "Release signing is not configured. Build will continue without a release signing config; " +
            "to sign artifacts, provide android/key.properties or ANDROID_KEYSTORE_PATH/ANDROID_KEYSTORE_PASSWORD/ANDROID_KEY_ALIAS/ANDROID_KEY_PASSWORD."
    )
}

android {
    namespace = "com.viso.caleesync"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.viso.caleesync"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
            storeFile = releaseKeystoreFile
            storePassword = releaseStorePassword
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}

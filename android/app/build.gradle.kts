import java.io.FileInputStream
import java.util.Properties
import org.gradle.api.GradleException

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

val releaseStoreFilePath = envStoreFile ?: keystoreProperties["storeFile"]?.toString()
val releaseStorePassword = envStorePassword ?: keystoreProperties["storePassword"]?.toString()
val releaseKeyAlias = envKeyAlias ?: keystoreProperties["keyAlias"]?.toString()
val releaseKeyPassword = envKeyPassword ?: keystoreProperties["keyPassword"]?.toString()

val releaseKeystoreFile = releaseStoreFilePath?.let { file(it) }
val missingSigningInputs = buildList {
    if (releaseStoreFilePath.isNullOrBlank()) {
        add("storeFile (key.properties: storeFile or env ANDROID_KEYSTORE_PATH)")
    } else if (releaseKeystoreFile?.exists() != true) {
        add("keystore file not found at '$releaseStoreFilePath'")
    }

    if (releaseStorePassword.isNullOrBlank()) {
        add("storePassword (key.properties: storePassword or env ANDROID_KEYSTORE_PASSWORD)")
    }
    if (releaseKeyAlias.isNullOrBlank()) {
        add("keyAlias (key.properties: keyAlias or env ANDROID_KEY_ALIAS)")
    }
    if (releaseKeyPassword.isNullOrBlank()) {
        add("keyPassword (key.properties: keyPassword or env ANDROID_KEY_PASSWORD)")
    }
}
val hasReleaseSigningConfig = missingSigningInputs.isEmpty()

val isReleaseBuildRequested =
    gradle.startParameter.taskNames.any { taskName -> taskName.contains("release", ignoreCase = true) }

if (!hasReleaseSigningConfig) {
    val signingRequirements =
        "android/key.properties or ANDROID_KEYSTORE_PATH/ANDROID_KEYSTORE_PASSWORD/ANDROID_KEY_ALIAS/ANDROID_KEY_PASSWORD"
    val missingInputsDescription = missingSigningInputs.joinToString(separator = "; ")
    if (isReleaseBuildRequested) {
        throw GradleException(
            "Release signing is required for release builds. Missing: $missingInputsDescription. Configure $signingRequirements."
        )
    }

    logger.warn(
        "Release signing is not configured for non-release tasks. Missing: $missingInputsDescription; " +
            "to sign artifacts, provide $signingRequirements."
    )
}

android {
    namespace = "com.viso.caleesync"
    compileSdk = 35
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
        targetSdk = 35
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

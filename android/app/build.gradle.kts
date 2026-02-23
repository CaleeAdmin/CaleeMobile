import com.android.build.gradle.internal.api.BaseVariantOutputImpl

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val isReleaseBuildRequested =
    gradle.startParameter.taskNames.any { taskName ->
        taskName.contains("release", ignoreCase = true)
    }

fun requiredEnv(name: String): String {
    return System.getenv(name)?.takeIf { it.isNotBlank() }
        ?: throw GradleException("Missing required environment variable for release signing: $name")
}

android {
    namespace = "com.viso.caleesync"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

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
        versionCode = 1
        versionName = "1.0.0"
    }

    signingConfigs {
        create("release") {
            if (isReleaseBuildRequested) {
                val keystorePath = requiredEnv("ANDROID_KEYSTORE_PATH")
                val keystorePassword = requiredEnv("ANDROID_KEYSTORE_PASSWORD")
                val keyAlias = requiredEnv("ANDROID_KEY_ALIAS")
                val keyPassword =
                    System.getenv("ANDROID_KEY_PASSWORD")
                        ?.takeIf { it.isNotBlank() }
                        ?: keystorePassword

                storeFile = file(keystorePath)
                if (!storeFile!!.exists()) {
                    throw GradleException("Keystore file not found at ANDROID_KEYSTORE_PATH: $keystorePath")
                }
                storePassword = keystorePassword
                this.keyAlias = keyAlias
                this.keyPassword = keyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }

    applicationVariants.all {
        if (buildType.name == "release") {
            outputs.all {
                val output = this as BaseVariantOutputImpl
                output.outputFileName = "caleesync-release-${versionName}(${versionCode}).apk"
            }
        }
    }
}

flutter {
    source = "../.."
}

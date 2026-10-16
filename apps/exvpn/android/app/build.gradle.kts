plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ru.exvpn.exvpn"
    compileSdk = flutter.compileSdkVersion
    // Plugins use NDK 28; the separately built Xray JNI remains pinned to NDK 27.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ru.exvpn.exvpn"
        // ExVPN v1 supports Android 11 and newer.
        minSdk = 30
        ndk { abiFilters.addAll(listOf("arm64-v8a", "x86_64")) }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Release signing is configured separately before distribution.
            // Never turn a release into a debug-signed package implicitly.
            signingConfig = null
        }
    }
    sourceSets.getByName("main").jniLibs.srcDir(rootProject.file("../../../.tools/artifacts/android-jni"))
}

val verifyExVpnCore by tasks.registering {
    doLast {
        for (abi in listOf("arm64-v8a", "x86_64")) {
            check(rootProject.file("../../../.tools/artifacts/android-jni/$abi/libexvpn.so").isFile) {
                "Missing ExVPN JNI for $abi. Run native/android/build.ps1 from the repository first."
            }
        }
    }
}
tasks.named("preBuild").configure { dependsOn(verifyExVpnCore) }

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

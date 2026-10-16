import java.io.File
import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// A build selects one fresh, verified snapshot. No fallback to mutable global
// JNI or an old notice directory is allowed when the environment is absent.
val exVpnPackageInputs = providers.environmentVariable("EXVPN_ANDROID_PACKAGE_INPUTS")
    .orNull?.takeIf { it.isNotBlank() }?.let { file(it) }

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
    sourceSets.getByName("main").jniLibs.setSrcDirs(
        exVpnPackageInputs?.let { listOf(it.resolve("jniLibs")) } ?: emptyList<File>()
    )
    sourceSets.getByName("main").assets.setSrcDirs(
        exVpnPackageInputs?.let { listOf(it.resolve("assets")) } ?: emptyList<File>()
    )
    // JNI is already stripped by the pinned native build. Preserve its exact
    // bytes so the delivered library remains bound to the notice inventory.
    packaging.jniLibs.keepDebugSymbols += "**/libexvpn.so"
}

val verifyExVpnPackageInputs by tasks.registering(Exec::class) {
    outputs.upToDateWhen { false }
    doFirst {
        val inputs = checkNotNull(exVpnPackageInputs) {
            "Missing ExVPN package snapshot. Use scripts/bootstrap/build-android-debug.ps1; direct Gradle packaging requires EXVPN_ANDROID_PACKAGE_INPUTS."
        }
        commandLine(
            "pwsh", "-NoProfile", "-File",
            rootProject.file("../../../scripts/release/verify-android-notices.ps1").absolutePath,
            "-InputDirectory", inputs.absolutePath,
            "-ExpectedVersion", "${flutter.versionName}+${flutter.versionCode}"
        )
    }
}
tasks.named("preBuild").configure { dependsOn(verifyExVpnPackageInputs) }

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ua.naiksoftware.elis"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true // flutter_local_notifications needs it
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ua.naiksoftware.elis"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 15: the Bluetooth link's insecure L2CAP and its permissions; one floor for TLS too
        minSdk = 35
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // libvtshim.so exists for these two only; a 32-bit APK would install without it
        // the Flutter plugin pre-fills armeabi-v7a, so replace the list rather than append
        ndk { abiFilters.clear(); abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// A release without the emulator shim would silently fall back to the text view on that ABI.
tasks.named("preBuild") {
    doFirst {
        for (abi in listOf("arm64-v8a", "x86_64")) {
            val so = file("src/main/jniLibs/$abi/libvtshim.so")
            if (!so.exists()) throw GradleException("Missing ${so.path}: run mobile/tool/build-vtshim.sh before building")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

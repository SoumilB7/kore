// :app — Kore for Android (phase 18 §5): the phone on KoreNet over its own embedded tailnet,
// beside the old debug app (its own applicationId). Native Kotlin views; :link holds the protocol.
plugins {
    id("com.android.application")
}

/** VERSION ("0.2.3") as Android's versionCode: 0·1 000 000 + 2·1 000 + 3. */
val koreVersion = rootProject.projectDir.resolve("../VERSION").readText().trim()
val koreVersionCode = koreVersion.split(".").map { it.toInt() }.let { (a, b, c) -> a * 1_000_000 + b * 1_000 + c }

android {
    namespace = "dev.kore.phone"
    compileSdk = 35
    defaultConfig {
        applicationId = "dev.kore.android"
        minSdk = 31
        targetSdk = 35
        versionCode = koreVersionCode
        versionName = koreVersion
        ndk { abiFilters += "arm64-v8a" }
    }
    buildTypes {
        release {
            // Unsigned here: the owner signs with the off-repo keystore (docs/android.md).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // The tailnet's .so stays uncompressed and 16 KB aligned in the APK (mapped in place).
    packaging { jniLibs { useLegacyPackaging = false } }
    testOptions { unitTests.isReturnDefaultValues = true }
    lint { checkReleaseBuilds = false }
}

dependencies {
    implementation(project(":tailnet"))
    implementation("androidx.recyclerview:recyclerview:1.4.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}

tasks.withType<Test>().configureEach {
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

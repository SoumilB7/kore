// :tailnet — the phone's embedded Tailscale node: the gomobile AAR built from go/ by
// scripts/build-tailnet.sh (cached by source hash, outside the repo), and the Kotlin around it
// (Keystore-sealed state, ConnectivityManager's interfaces and default route, binding to the
// current network). arm64 only.
plugins {
    id("com.android.library")
}

android {
    namespace = "dev.kore.tailnet"
    compileSdk = 35
    defaultConfig {
        minSdk = 31
        ndk { abiFilters += "arm64-v8a" }
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging { jniLibs { keepDebugSymbols += "**/libgojni.so" } }
}

androidComponents {
    onVariants { v -> v.sources.jniLibs?.addStaticSourceDirectory("build/gomobile/jni") }
}

val gomobile = layout.projectDirectory.dir("build/gomobile")
val buildTailnet = tasks.register<Exec>("buildTailnet") {
    description = "Builds (or takes from the cache) the gomobile AAR and unpacks it."
    commandLine(rootProject.projectDir.resolve("scripts/build-tailnet.sh").path)
    inputs.dir("go")
    outputs.dir(gomobile)
}
tasks.named("preBuild") { dependsOn(buildTailnet) }

dependencies {
    api(project(":link"))
    api(files(gomobile.file("classes.jar")).builtBy(buildTailnet))
}

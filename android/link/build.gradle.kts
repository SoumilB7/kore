// :link — the phone's half of link 2.0 in plain Kotlin on the JVM: NetFrame and the client
// session, identity proofs over B, raises, the node clients and their machine, the outbox,
// Control's builders, and signed updates. No Android here: the app wraps it (Keystore keys, the
// embedded tailnet, the screens), and every byte is checked on the Mac against
// Tests/Fixtures/link/v2.
plugins {
    kotlin("jvm")
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation("com.google.crypto.tink:tink-android:1.24.0")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}

// The contract, read in place: the public repo's fixtures and the Mac's release key.
val repoRoot = rootProject.projectDir.resolve("..").canonicalFile
tasks.test {
    systemProperty("kore.fixtures", repoRoot.resolve("Tests/Fixtures/link/v2").path)
    systemProperty("kore.releaseKey", repoRoot.resolve("Sources/KoreCore/ReleaseKey.swift").path)
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

// Plain Kotlin only: no `android.*` imports in :link's sources.
val noAndroid = tasks.register("noAndroid") {
    val sources = fileTree("src") { include("**/*.kt") }
    inputs.files(sources)
    doLast {
        val bad = sources.files.filter { f -> f.readLines().any { it.trimStart().startsWith("import android.") || it.contains("android.") && it.trimStart().startsWith("import ") } }
        if (bad.isNotEmpty()) throw GradleException("android imports in :link: " + bad.joinToString { it.name })
        println("noAndroid: ${sources.files.size} files, no android imports")
    }
}
tasks.named("check") { dependsOn(noAndroid) }
tasks.named("test") { dependsOn(noAndroid) }

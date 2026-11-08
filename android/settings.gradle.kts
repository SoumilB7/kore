// Kore for Android: the phone's side of KoreNet. :link is plain Kotlin on the JVM (link 2.0, the
// node clients, updates), tested on the Mac against Tests/Fixtures/link/v2; :tailnet is the
// embedded Tailscale node (a gomobile AAR built from tailnet/go); :app is the app.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal { content { includeGroupByRegex("org\\.gradle.*") } }
    }
    plugins {
        id("com.android.application") version "9.4.1"
        id("com.android.library") version "9.4.1"
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "kore-android"
include(":link")
// The Android modules need the SDK; `-Pkore.jvmOnly` leaves them out (link tests on a bare JDK).
if (!providers.gradleProperty("kore.jvmOnly").isPresent) {
    include(":tailnet")
    include(":app")
}

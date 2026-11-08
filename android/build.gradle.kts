// Versions for every module, in one place. Every artifact's checksum is pinned in
// gradle/verification-metadata.xml.
plugins {
    kotlin("jvm") version "2.4.21" apply false
    id("com.android.application") version "9.4.1" apply false
    id("com.android.library") version "9.4.1" apply false
}

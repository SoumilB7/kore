# The Android toolchain, all in user space under ~/Library/Android: JDK 17, the SDK, the NDK and
# Gradle's own cache (GRADLE_USER_HOME), so nothing lands in ~/.gradle. Sourced by the scripts here.
export ANDROID_ROOT="${ANDROID_ROOT:-$HOME/Library/Android}"
export JAVA_HOME="${KORE_JAVA_HOME:-$ANDROID_ROOT/jdk-17/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$ANDROID_ROOT/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.2.13676358}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$ANDROID_ROOT/gradle}"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
# Gradle itself: the distribution gradle/wrapper/gradle-wrapper.properties pins (its SHA-256
# checked when it was fetched), run straight from GRADLE_USER_HOME. No wrapper jar in the repo.
kore_gradle() {
    local dist version
    version=$(sed -n 's/^distributionUrl=.*gradle-\(.*\)-bin\.zip$/\1/p' "$KORE_ANDROID/gradle/wrapper/gradle-wrapper.properties")
    dist=$(ls -d "$GRADLE_USER_HOME"/wrapper/dists/gradle-"$version"-bin/*/gradle-"$version" 2>/dev/null | head -1)
    if [[ -z "$dist" ]]; then
        echo "gradle $version isn't in $GRADLE_USER_HOME: run scripts/fetch-gradle.sh once" >&2
        return 2
    fi
    "$dist/bin/gradle" -p "$KORE_ANDROID" "$@"
}

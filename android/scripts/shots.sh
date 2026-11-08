#!/bin/zsh
# The phone app's screens, seen without a phone: an Android 15 emulator (AVD kore35, headless, no
# window), the debug build in its demo (a Mac and a box from app/src/debug/assets/demo, no
# Tailscale), and a screenshot of each screen at the widths and font scales the design spec checks.
#
#   shots.sh [out dir]      default ~/Library/Application Support/KoreDev/scratch/shots/<time>/
#
# Writes <screen>-<width>dp-<scale>x.png for Home, a device, a chat (a wide table, a permission card)
# and Settings, at 320/360/412 dp and font scale 1.0 and 2.0. Boots the emulator if it isn't up and
# leaves it running (`adb -s emulator-5580 emu kill` stops it). Input on the emulator only.
set -u
export KORE_ANDROID="${0:A:h:h}"
source "$KORE_ANDROID/scripts/env.sh"
sdk="$ANDROID_HOME"
adb="$sdk/platform-tools/adb"
export ANDROID_SERIAL=emulator-5580 ANDROID_SDK_ROOT="$sdk" ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/Library/Android/avd}"
out=${1:-"$HOME/Library/Application Support/KoreDev/scratch/shots/$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$out"
pkg=dev.kore.android
mac=b3d9e1f0-7a2c-4e6b-8d41-5c0f9a3e2b02
chat=6E1F0C2A-0000-4000-8000-000000000001

[[ -d "$ANDROID_AVD_HOME/kore35.avd" ]] || {
    print "no AVD kore35: sdkmanager \"system-images;android-35;default;arm64-v8a\" emulator, then"
    print "  avdmanager create avd -n kore35 -k \"system-images;android-35;default;arm64-v8a\" -d pixel_6"
    exit 2
}
if [[ $("$adb" get-state 2>/dev/null) != device ]]; then
    nohup "$sdk/emulator/emulator" -avd kore35 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -port 5580 >/tmp/kore-emulator.log 2>&1 &
    for i in {1..100}; do [[ $("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]] && break; sleep 3; done
fi
"$adb" root >/dev/null 2>&1; sleep 2; "$adb" wait-for-device
"$adb" shell svc power stayon true; "$adb" shell input keyevent KEYCODE_WAKEUP; "$adb" shell wm dismiss-keyguard

(cd "$KORE_ANDROID" && kore_gradle --offline --quiet :app:assembleDebug) || { print "debug build failed"; exit 1; }
"$adb" install -r "$KORE_ANDROID/app/build/outputs/apk/debug/app-debug.apk" >/dev/null || { print "install failed"; exit 1; }
"$adb" shell run-as $pkg touch files/demo

shot() {
    "$adb" shell am force-stop $pkg
    "$adb" shell am start -W -n "$pkg/dev.kore.phone.ui.$2" "${@:3}" >/dev/null 2>&1
    sleep 3
    "$adb" exec-out screencap -p > "$out/$1.png"
}
density=$("$adb" shell wm density | awk '/Physical/ {print $3}' | tr -d '\r')
for dp in 320 360 412; do
    "$adb" shell wm size $(( dp * density / 160 ))x$(( dp * density / 160 * 20 / 9 ))
    for scale in 1.0 2.0; do
        "$adb" shell settings put system font_scale $scale
        shot "home-${dp}dp-${scale}x" HomeActivity
        shot "device-${dp}dp-${scale}x" DeviceActivity --es node $mac
        shot "chat-${dp}dp-${scale}x" ChatActivity --es node $mac --es chat $chat
        shot "settings-${dp}dp-${scale}x" SettingsActivity --es node $mac
    done
done
"$adb" shell wm size reset; "$adb" shell settings put system font_scale 1.0
"$adb" logcat -d -s AndroidRuntime:E > "$out/crashes.txt"
print "$(ls "$out"/*.png | wc -l | tr -d ' ') screenshots in $out$( [[ -s "$out/crashes.txt" ]] && print " · CRASHES: see crashes.txt")"

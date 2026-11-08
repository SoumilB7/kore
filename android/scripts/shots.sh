#!/bin/zsh
# The phone app's screens, seen without a phone: an Android 15 emulator (AVD kore35, headless, no
# window), the debug build in its demo (a Mac and a box from app/src/debug/assets/demo, no
# Tailscale), and a screenshot of each screen at the widths and font scales the design spec checks.
#
#   shots.sh [out dir]      default ~/Library/Application Support/KoreDev/scratch/shots/<time>/
#
# Writes <screen>-<width>dp-<scale>x.png for Home, a device, a chat (a wide table, a permission card)
# and Settings, at the sizes the design spec checks (§7, §9): 320/360/412 dp at font scale 1.0 and
# 2.0, 360 dp at 1.3 and 1.5, landscape 780 × 360, and 360 dp with animations off (still-*.png).
# Then the device's states from the demo's scenarios (state-<scenario>.png), and accounts' usage
# (usage-<device|chat>-<cli>-<normal|near|limit>.png: a device's Accounts, a chat's options sheet
# opened by its mode pill's identity). KORE_SHOTS=usage takes the usage ones alone. Boots the emulator if
# it isn't up and leaves it running (`adb -s emulator-5580 emu kill` stops it). Input on the
# emulator only.
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
demo=/data/data/$pkg/files/demo
"$adb" shell "run-as $pkg sh -c 'echo -n > $demo'"

shot() {
    "$adb" shell am force-stop $pkg
    "$adb" shell am start -W -n "$pkg/dev.kore.phone.ui.$2" "${@:3}" >/dev/null 2>&1
    sleep 3
    "$adb" exec-out screencap -p > "$out/$1.png"
}
box=0e4c2a91-5b7d-4f3e-9a61-2d8c7b5e1f04
# Accounts' usage (link 1.14) as each device pushes it: normal, near a limit (amber), at one (red).
usage() {
    "$adb" shell wm size reset; "$adb" shell settings put system font_scale 1.0
    for sc in normal near limit; do
        "$adb" shell "run-as $pkg sh -c 'echo -n $( [[ $sc == normal ]] && print usage || print usage-$sc ) > $demo'"
        shot "usage-device-mac-$sc" DeviceActivity --es node $mac
        shot "usage-device-box-$sc" DeviceActivity --es node $box
        for c in claude:$mac:$chat codex:$mac:6E1F0C2A-0000-4000-8000-000000000005 boxclaude:$box:6E1F0C2A-0000-4000-8000-000000000010 boxcodex:$box:6E1F0C2A-0000-4000-8000-000000000013; do
            parts=(${(s.:.)c})
            "$adb" shell am force-stop $pkg
            "$adb" shell am start -W -n "$pkg/dev.kore.phone.ui.ChatActivity" --es node ${parts[2]} --es chat ${parts[3]} >/dev/null 2>&1
            sleep 3
            # The mode pill or Model chip, by its identity: the options sheet opens in-process.
            "$adb" shell am broadcast -a dev.kore.android.debug.TAP --es desc Mode -n $pkg/dev.kore.phone.debug.Hooks >/dev/null
            sleep 2
            "$adb" exec-out screencap -p > "$out/usage-chat-${parts[1]}-$sc.png"
        done
    done
    "$adb" shell "run-as $pkg sh -c 'echo -n > $demo'"
}
if [[ ${KORE_SHOTS:-all} == usage ]]; then
    usage
    "$adb" logcat -d -s AndroidRuntime:E > "$out/crashes.txt"
    print "$(ls "$out"/*.png | wc -l | tr -d ' ') screenshots in $out$( [[ -s "$out/crashes.txt" ]] && print " · CRASHES: see crashes.txt")"
    exit 0
fi
density=$("$adb" shell wm density | awk '/Physical/ {print $3}' | tr -d '\r')
px() { print $(( $1 * density / 160 )); }
four() {
    shot "home-$1" HomeActivity
    shot "device-$1" DeviceActivity --es node $mac
    shot "chat-$1" ChatActivity --es node $mac --es chat $chat
    shot "settings-$1" SettingsActivity --es node $mac
}
size() { "$adb" shell wm size $(px $1)x$(px $2); }
scale() { "$adb" shell settings put system font_scale $1; }
for dp in 320 360 412; do
    size $dp $(( dp * 20 / 9 ))
    for s in 1.0 2.0; do scale $s; four "${dp}dp-${s}x"; done
done
size 360 800
for s in 1.3 1.5; do scale $s; four "360dp-${s}x"; done
scale 1.0
# Landscape: the same 560 column (spec §7).
size 780 360; four "780x360dp"
# "Remove animations": the spinner, the breathing ring and the shimmer hold still.
size 360 800
anim() { for k in animator_duration_scale transition_animation_scale window_animation_scale; do "$adb" shell settings put global $k $1; done; }
anim 0; four "360dp-still"; anim 1
# The device's states, one demo scenario each.
for sc in waiting no-windows asleep; do
    "$adb" shell "run-as $pkg sh -c 'echo -n $sc > $demo'"
    shot "state-$sc" DeviceActivity --es node $mac
done
"$adb" shell "run-as $pkg sh -c 'echo -n > $demo'"
usage
"$adb" shell wm size reset; scale 1.0
"$adb" logcat -d -s AndroidRuntime:E > "$out/crashes.txt"
print "$(ls "$out"/*.png | wc -l | tr -d ' ') screenshots in $out$( [[ -s "$out/crashes.txt" ]] && print " · CRASHES: see crashes.txt")"

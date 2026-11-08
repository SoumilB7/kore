#!/bin/zsh
# Builds the :tailnet AAR from tailnet/go with gomobile, once per source change: the AAR is cached
# outside the repo by a hash of the Go sources, go.sum and these flags, then unpacked into
# tailnet/build/gomobile for Gradle (classes.jar + jni/arm64-v8a/libgojni.so). arm64 only,
# stripped, trimmed paths, 16 KB pages (Android 15+ devices with 16 KB pages load it).
# Needs Go (/opt/homebrew/bin/go), gomobile + gobind in ~/go/bin, and the NDK in env.sh.
set -eu
export KORE_ANDROID="${0:A:h:h}"
source "$KORE_ANDROID/scripts/env.sh"
GO="${KORE_GO:-/opt/homebrew/bin/go}"
export PATH="${GO:h}:$HOME/go/bin:$PATH"
src="$KORE_ANDROID/tailnet/go"
out="$KORE_ANDROID/tailnet/build/gomobile"
cache="${KORE_TAILNET_CACHE:-$HOME/Library/Caches/KoreDev/android-tailnet}"
# Features a phone node never uses, left out of the binary (spike 0g's list).
tags="ts_omit_ssh,ts_omit_taildrop,ts_omit_webclient,ts_omit_capture,ts_omit_drive,ts_omit_relayserver,ts_omit_aws,ts_omit_kube,ts_omit_tap,ts_omit_tpm,ts_omit_systray,ts_omit_synology,ts_omit_clientupdate,ts_omit_appconnectors,ts_omit_advertiseexitnode,ts_omit_advertiseroutes,ts_omit_bird,ts_omit_completion,ts_omit_completion_scripts,ts_omit_netlog,ts_omit_oauthkey,ts_omit_identityfederation,ts_omit_portlist,ts_omit_posture,ts_omit_wakeonlan,ts_omit_webbrowser,ts_omit_qrcodes,ts_omit_desktop_sessions,ts_omit_flashappliance,ts_omit_dbus,ts_omit_networkmanager,ts_omit_resolved,ts_omit_iptables,ts_omit_linuxdnsfight,ts_omit_sdnotify,ts_omit_ace,ts_omit_cloud,ts_omit_doctor,ts_omit_cliconndiag,ts_omit_debugportmapper,ts_omit_debugeventbus,ts_omit_tundevstats,ts_omit_listenrawdisco,ts_omit_gro,ts_omit_androidbin,ts_omit_syslog,ts_omit_colorable,ts_omit_linkspeed,ts_omit_c2n,ts_omit_useexitnode,ts_omit_conn25"
ldflags="-s -w -extldflags=-Wl,-z,max-page-size=16384"
api=31
key=$( { cat "$src"/go.mod "$src"/go.sum; for f in "$src"/*.go(on); do [[ $f == *_test.go ]] || cat "$f"; done; print "$tags $ldflags $api arm64"; } | shasum -a 256 | cut -c1-16)
aar="$cache/tailnet-$key.aar"
if [[ ! -f "$aar" ]]; then
    mkdir -p "$cache"
    print "tailnet: building $aar (gomobile, a few minutes the first time)"
    ( cd "$src" && GOFLAGS=-mod=mod gomobile bind -target=android/arm64 -androidapi "$api" -trimpath \
        -ldflags="$ldflags" -tags "$tags" -javapkg dev.kore.tailnet.bind -o "$aar.tmp.aar" . )
    mv "$aar.tmp.aar" "$aar"
    rm -f "$aar.tmp-sources.jar" "${aar%.aar}-sources.jar"
    # Older AARs of other sources go.
    ls -t "$cache"/tailnet-*.aar | tail -n +4 | xargs rm -f
fi
if [[ ! -f "$out/.key" || "$(cat "$out/.key")" != "$key" ]]; then
    rm -rf "$out" && mkdir -p "$out"
    unzip -q -o "$aar" classes.jar 'jni/*' -d "$out"
    print "$key" > "$out/.key"
fi
so="$out/jni/arm64-v8a/libgojni.so"
readelf="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf"
align=$("$readelf" -lW "$so" | awk '$1=="LOAD"{print $NF}' | sort -u | tr '\n' ' ')
for a in ${=align}; do (( a >= 0x4000 )) || { print "tailnet: LOAD alignment $a < 16 KB"; exit 1; }; done
print "tailnet: $(du -k "$aar" | cut -f1) KB aar, $(du -k "$so" | cut -f1) KB .so, LOAD align $align"

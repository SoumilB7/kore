#!/bin/zsh
# Keeps the phone remote's layers apart, and out of Kore itself:
# - KoreRemote (the protocol, sessions, policy) has no app or view code;
# - KorePhone (the bridge to Kore) does no networking or crypto of its own;
# - KoreUI and the Kore app never import the remote, so Kore carries none of it.
cd "$(dirname "$0")/.." || exit 2
fail=0
check() {
  local dir=$1 pattern=$2 why=$3
  local hits
  hits=$(grep -rnE "$pattern" "$dir" --include='*.swift' 2>/dev/null)
  if [[ -n $hits ]]; then
    print -r -- "$hits"
    print -r -- "  ↳ $why"
    fail=1
  fi
}
check Sources/KoreRemote '^[[:space:]]*(@testable )?import (KoreUI|AppKit|SwiftUI|KorePhone)\b' "KoreRemote stays free of the app and its views"
check Sources/KorePhone '^[[:space:]]*import (Network|CryptoKit|Security)\b|URLSession|NWConnection|NWListener' "KorePhone bridges Kore to KoreRemote; transport and crypto live in KoreRemote"
check Sources/KoreUI '^[[:space:]]*(@testable )?import (KoreRemote|KorePhone)\b' "Kore itself carries no phone remote"
check Sources/Kore '^[[:space:]]*(@testable )?import (KoreRemote|KorePhone)\b' "Kore itself carries no phone remote"
if grep -nE '"KoreUI".*dependencies: \[[^]]*"(KoreRemote|KorePhone)"' Package.swift || grep -nE 'name: "KoreUI", dependencies: \[[^]]*(KoreRemote|KorePhone)' Package.swift; then
  print "  ↳ KoreUI must not depend on the phone remote"
  fail=1
fi
if grep -nE 'name: "Kore", dependencies: \[[^]]*(KoreRemote|KorePhone)' Package.swift; then
  print "  ↳ the Kore app must not depend on the phone remote"
  fail=1
fi
(( fail )) && exit 1
print "remote layers clean"

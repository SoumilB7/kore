# Third-party notices

Kore bundles the following open-source code. Their full license texts are in
[`Resources/ThirdParty`](Resources/ThirdParty) and ship inside the app, in
`Kore.app/Contents/Resources/ThirdParty`.

| Project | Used for | License |
|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | The built-in terminal | MIT |
| [Mermaid](https://github.com/mermaid-js/mermaid) | Diagram previews, bundled so it never loads from the network | MIT |

## Kore for Android

The Android app (`android/`) bundles the following. Its embedded Tailscale node is compiled from
Go into `libgojni.so`; each project's license text is in its source at the version
`android/tailnet/go/go.mod` pins.

| Project | Used for | License |
|---|---|---|
| [Tailscale](https://github.com/tailscale/tailscale) (`tsnet`) | The phone's own node on your tailnet | BSD-3-Clause |
| [gVisor](https://github.com/google/gvisor) (netstack) | Tailscale's userspace TCP/IP stack | Apache-2.0 |
| [wireguard-go](https://github.com/tailscale/wireguard-go) | WireGuard, as Tailscale forks it | MIT |
| [Go](https://go.dev) and `golang.org/x/*` | The runtime and libraries the node is built with | BSD-3-Clause |
| [gomobile](https://github.com/golang/mobile) | The Kotlin ↔ Go binding | BSD-3-Clause |
| [Kotlin](https://kotlinlang.org), [kotlinx.coroutines](https://github.com/Kotlin/kotlinx.coroutines), [kotlinx.serialization](https://github.com/Kotlin/kotlinx.serialization) | The app's language and libraries | Apache-2.0 |
| [Tink](https://github.com/tink-crypto/tink-java) | Ed25519 checks of signed releases | Apache-2.0 |
| [AndroidX RecyclerView](https://developer.android.com/jetpack/androidx) | The chat transcript list | Apache-2.0 |

package dev.kore.phone

import dev.kore.link.net.Tailnet
import dev.kore.link.node.NodeDialer
import dev.kore.link.trust.Device

/**
 * KoreNet stood in for: a tailnet, a dialer and the devices the phone knows, so every screen can
 * be shown with no Mac, box or Tailscale (an emulator's screenshots). Only a debug build sets one,
 * before the app starts; a release build never does, and then nothing here is used.
 */
interface StandIn {
    val tailnet: Tailnet
    val dialer: NodeDialer
    val devices: List<Device>
}

object StandIns {
    @Volatile var current: StandIn? = null
}

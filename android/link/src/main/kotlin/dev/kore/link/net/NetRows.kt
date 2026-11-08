package dev.kore.link.net

/** One network interface as the tailnet shim's `SetInterfaces` reads it. */
data class NetRow(
    val name: String,
    val index: Int,
    val mtu: Int,
    val up: Boolean,
    val loopback: Boolean,
    val pointToPoint: Boolean,
    val multicast: Boolean,
    /** `ip/prefix` */
    val addrs: List<String>,
    /** The active network's interface: tsnet's default route. */
    val default: Boolean,
    /** Its IPv4 default gateway, or "". */
    val gateway: String,
)

/**
 * Which interfaces tsnet sees. An empty list means it never reaches control (no sign-in URL, no
 * peers), and some phones list no networks from ConnectivityManager for a moment, or none with an
 * interface name: then the active network alone, then java.net's own list.
 */
object NetRows {
    fun pick(all: List<NetRow>, active: () -> NetRow?, java: () -> List<NetRow>): List<NetRow> {
        if (all.isNotEmpty()) return all
        active()?.let { return listOf(it.copy(default = true)) }
        val rows = java().filter { it.up && !it.loopback && it.addrs.isNotEmpty() }
        // The default: the first with an IPv4 address (mobile data and Wi-Fi both have one).
        val first = rows.indexOfFirst { r -> r.addrs.any { '.' in it } }.takeIf { it >= 0 } ?: 0
        return rows.mapIndexed { i, r -> if (i == first) r.copy(default = true) else r }
    }
}

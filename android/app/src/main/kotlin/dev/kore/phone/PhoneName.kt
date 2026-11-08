package dev.kore.phone

import android.content.Context
import android.os.Build
import android.provider.Settings

/**
 * The phone's name as its owner knows it, for the Mac's Allow card and Devices row: the name set
 * in the phone's settings (`Settings.Global.DEVICE_NAME`: "OnePlus Nord CE 2", or the owner's own),
 * else the maker and its marketing model (from the system properties OEMs set), else
 * `Build.MODEL` ("CPH2381"), else "Android".
 */
object PhoneName {
    /** The system properties OEMs keep the marketing model in, first found wins. */
    private val marketProperties = listOf(
        "ro.product.marketname", "ro.vendor.oplus.market.name", "ro.oppo.market.name", "ro.product.vendor.marketname",
        "ro.config.marketing_name", "ro.product.odm.marketname",
    )

    fun of(context: Context): String = pick(
        deviceName = runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull(),
        manufacturer = Build.MANUFACTURER,
        marketName = marketProperties.firstNotNullOfOrNull { property(it) },
        model = Build.MODEL,
    )

    /**
     * The name from what the phone says. A device name that is only the model code (some phones
     * leave it so) gives way to the marketing name; the maker is said once ("OnePlus Nord CE 2",
     * never "OnePlus OnePlus Nord CE 2").
     */
    fun pick(deviceName: String?, manufacturer: String?, marketName: String?, model: String?): String {
        val name = deviceName?.trim().orEmpty()
        val code = model?.trim().orEmpty()
        if (name.isNotEmpty() && !name.equals(code, ignoreCase = true)) return name
        val market = marketName?.trim().orEmpty()
        if (market.isNotEmpty() && !market.equals(code, ignoreCase = true)) {
            val maker = manufacturer?.trim().orEmpty().replaceFirstChar { it.titlecase() }
            return if (maker.isEmpty() || market.startsWith(maker, ignoreCase = true)) market else "$maker $market"
        }
        return code.ifEmpty { name.ifEmpty { "Android" } }
    }

    /** A system property by reflection (`android.os.SystemProperties` is hidden), or null. */
    private fun property(key: String): String? = runCatching {
        Class.forName("android.os.SystemProperties").getMethod("get", String::class.java).invoke(null, key) as? String
    }.getOrNull()?.trim()?.takeIf { it.isNotEmpty() }
}

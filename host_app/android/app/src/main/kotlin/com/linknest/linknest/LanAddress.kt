package com.linknest.linknest

/** LinkNest accepts RFC 1918 private IPv4 ranges. */
internal fun isSupportedLanIpv4(value: String): Boolean {
    val parts = value.split('.')
    if (parts.size != 4) return false
    val octets = parts.map { it.toIntOrNull() ?: return false }
    if (octets.any { it !in 0..255 }) return false
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] in 16..31) ||
        (octets[0] == 192 && octets[1] == 168)
}

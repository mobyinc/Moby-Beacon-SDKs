package com.mobyinc.beacon

/** Longest `userId`, `category`, `action` or details key the API accepts. */
internal const val MAX_FIELD_LENGTH = 255
private const val MAX_STRING_LENGTH = MAX_FIELD_LENGTH
private const val MAX_DETAIL_KEYS = 50
private const val MAX_DETAIL_STRING_LENGTH = 1000

/**
 * Checks [event] against the API's ingest rules. Throws
 * [IllegalArgumentException] with a descriptive message on the first violation.
 */
internal fun validateEvent(event: MobyBeaconEvent) {
    validateRequiredString(event.userId, "userId")
    validateRequiredString(event.category, "category")
    validateRequiredString(event.action, "action")

    val details = event.details ?: return

    require(details.size <= MAX_DETAIL_KEYS) {
        "details must have at most $MAX_DETAIL_KEYS keys"
    }
    for ((key, value) in details) {
        require(key.length <= MAX_STRING_LENGTH) {
            "details key must be at most $MAX_STRING_LENGTH characters"
        }
        require(!key.contains('\u0000')) {
            "details keys must not contain NUL characters"
        }
        when (value) {
            null, is Boolean -> {}
            is String -> {
                require(value.length <= MAX_DETAIL_STRING_LENGTH) {
                    "details string values must be at most $MAX_DETAIL_STRING_LENGTH characters"
                }
                require(!value.contains('\u0000')) {
                    "details.$key must not contain NUL characters"
                }
            }
            is Number -> {
                val finite = when (value) {
                    is Double -> value.isFinite()
                    is Float -> value.isFinite()
                    else -> true
                }
                require(finite) { "details.$key must be a finite number" }
            }
            else -> throw IllegalArgumentException(
                "details.$key must be a string, number, boolean, or null " +
                    "— not a nested object or array"
            )
        }
    }
}

/**
 * The subset of the `userId` rules checked on the config and on `setUserId`:
 * not blank, at most 255 characters, no NUL.
 */
internal fun validateUserId(userId: String) {
    require(userId.isNotBlank()) { "userId must not be empty" }
    require(userId.length <= MAX_FIELD_LENGTH) {
        "userId must be at most $MAX_FIELD_LENGTH characters"
    }
    require(!userId.contains('\u0000')) { "userId must not contain NUL characters" }
}

/**
 * True when [endpoint] is an absolute `http` or `https` URL with a host.
 *
 * Splits the text the way `android.net.Uri.parse` does, so the check does not
 * need Android: the scheme is everything before the first `:`, the authority
 * follows `//` up to the next `/`, `\`, `?` or `#`, and the host is the part
 * of the authority after any `user@` and before any `:port`.
 */
internal fun isAbsoluteHttpUrl(endpoint: String): Boolean {
    val colon = endpoint.indexOf(':')
    if (colon == -1) return false
    val scheme = endpoint.substring(0, colon)
    if (!scheme.equals("http", ignoreCase = true) && !scheme.equals("https", ignoreCase = true)) {
        return false
    }
    if (!endpoint.startsWith("//", colon + 1)) return false
    var end = colon + 3
    while (end < endpoint.length && endpoint[end] !in "/\\?#") end++
    val authority = endpoint.substring(colon + 3, end)
    val hostStart = authority.lastIndexOf('@') + 1
    val portColon = authority.indexOf(':', hostStart)
    val host = if (portColon == -1) authority.substring(hostStart) else authority.substring(hostStart, portColon)
    return host.isNotEmpty()
}

private fun validateRequiredString(value: String, field: String) {
    require(value.isNotEmpty()) { "$field is required and must be a non-empty string" }
    if (field == "userId") {
        require(value.isNotBlank()) { "userId must not be blank" }
    }
    require(value.length <= MAX_STRING_LENGTH) {
        "$field must be at most $MAX_STRING_LENGTH characters"
    }
    require(!value.contains('\u0000')) { "$field must not contain NUL characters" }
}

/**
 * Returns [event] with every unpaired UTF-16 surrogate in its strings
 * (`userId`, `category`, `action`, details keys and string values) replaced by
 * U+FFFD, and its details copied into an unmodifiable map.
 *
 * Truncating text in the middle of an emoji leaves a lone surrogate. JSON
 * encoding writes it as an escape that PostgreSQL rejects, which would fail the
 * whole batch on every retry.
 */
internal fun sanitizeEvent(event: MobyBeaconEvent): MobyBeaconEvent {
    val details = event.details
    val sanitizedDetails: Map<String, Any?>? = if (details == null) {
        null
    } else {
        val copy = LinkedHashMap<String, Any?>()
        for ((key, value) in details) {
            copy[sanitizeString(key)] = if (value is String) sanitizeString(value) else value
        }
        java.util.Collections.unmodifiableMap(copy)
    }
    return MobyBeaconEvent(
        userId = sanitizeString(event.userId),
        category = sanitizeString(event.category),
        action = sanitizeString(event.action),
        timestampMs = event.timestampMs,
        details = sanitizedDetails,
    )
}

/**
 * Replaces unpaired UTF-16 surrogates in [value] with U+FFFD. Returns [value]
 * itself when there are none.
 */
internal fun sanitizeString(value: String): String {
    var units: CharArray? = null
    var i = 0
    while (i < value.length) {
        val unit = value[i]
        if (unit < '\uD800' || unit > '\uDFFF') {
            i++
            continue
        }
        if (unit <= '\uDBFF' && i + 1 < value.length) {
            val next = value[i + 1]
            if (next >= '\uDC00' && next <= '\uDFFF') {
                i += 2 // A valid pair.
                continue
            }
        }
        if (units == null) units = value.toCharArray()
        units[i] = '�'
        i++
    }
    return if (units == null) value else String(units)
}

package com.calee.caleesync

import java.util.Calendar
import java.util.TimeZone

internal object AllDayUtcNormalizer {

    fun isUtcMidnight(rawMs: Long): Boolean {
        val dayMs = 24L * 60L * 60L * 1000L
        val remainder = ((rawMs % dayMs) + dayMs) % dayMs
        return remainder == 0L
    }

    fun normalizeAllDayUtcDateBoundary(rawMs: Long, sourceTimezone: String?): Long {
        if (isUtcMidnight(rawMs)) {
            return rawMs
        }

        val sourceTz = TimeZone.getTimeZone(
            sourceTimezone?.takeIf { it.isNotBlank() } ?: TimeZone.getDefault().id
        )

        val source = Calendar.getInstance(sourceTz).apply {
            timeInMillis = rawMs
        }

        return Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(Calendar.YEAR, source.get(Calendar.YEAR))
            set(Calendar.MONTH, source.get(Calendar.MONTH))
            set(Calendar.DAY_OF_MONTH, source.get(Calendar.DAY_OF_MONTH))
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }
}

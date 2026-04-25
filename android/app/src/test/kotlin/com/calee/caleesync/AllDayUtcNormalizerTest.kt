package com.calee.caleesync

import org.junit.Assert.assertEquals
import org.junit.Test

class AllDayUtcNormalizerTest {

    @Test
    fun `keeps utc date-only input unchanged`() {
        val utcMidnight = 1777075200000L // 2026-04-25T00:00:00Z

        val normalized = AllDayUtcNormalizer.normalizeAllDayUtcDateBoundary(utcMidnight, null)

        assertEquals(utcMidnight, normalized)
    }

    @Test
    fun `converts legacy perth local midnight to utc date boundary`() {
        val legacyPerthMidnightUtcInstant = 1777046400000L // 2026-04-24T16:00:00Z
        val expectedUtcBoundary = 1777075200000L // 2026-04-25T00:00:00Z

        val normalized = AllDayUtcNormalizer.normalizeAllDayUtcDateBoundary(
            legacyPerthMidnightUtcInstant,
            "Australia/Perth"
        )

        assertEquals(expectedUtcBoundary, normalized)
    }

    @Test
    fun `converts legacy los angeles local midnight to utc date boundary`() {
        val legacyLaMidnightUtcInstant = 1777100400000L // 2026-04-25T07:00:00Z
        val expectedUtcBoundary = 1777075200000L // 2026-04-25T00:00:00Z

        val normalized = AllDayUtcNormalizer.normalizeAllDayUtcDateBoundary(
            legacyLaMidnightUtcInstant,
            "America/Los_Angeles"
        )

        assertEquals(expectedUtcBoundary, normalized)
    }
}
